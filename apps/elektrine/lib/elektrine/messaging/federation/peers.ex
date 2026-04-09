defmodule Elektrine.Messaging.Federation.Peers do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor
  alias Elektrine.Messaging.Federation.{Contexts, Discovery, Runtime, State, Utils}

  alias Elektrine.Messaging.{
    ChatConversation,
    Federation.PeerPolicies,
    FederationAccountPresenceState,
    FederationMembershipState,
    FederationRoomPresenceState
  }

  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  def enabled?, do: Runtime.enabled?()

  def peers do
    Runtime.configured_peers()
    |> PeerPolicies.apply_runtime_policies()
  end

  def incoming_peer(domain) when is_binary(domain) do
    case resolve_peer(domain) do
      %{allow_incoming: true} = peer -> peer
      _ -> nil
    end
  end

  def incoming_peer(_domain), do: nil

  def outgoing_peers do
    Enum.filter(peers(), & &1.allow_outgoing)
  end

  def outgoing_peer(domain) when is_binary(domain) do
    case resolve_peer(domain) do
      %{allow_outgoing: true} = peer -> peer
      _ -> nil
    end
  end

  def outgoing_peer(_domain), do: nil

  def local_domain, do: Runtime.local_domain()

  def list_server_presence_states(server_id) when is_integer(server_id) do
    server_presence_states_query(server_id)
    |> Repo.all()
    |> normalize_presence_states()
  end

  def list_server_presence_states(_server_id), do: []

  def list_visible_server_presence_states(server_id, user_id)
      when is_integer(server_id) and is_integer(user_id) do
    server_presence_states_query(server_id, user_id)
    |> Repo.all()
    |> normalize_presence_states()
  end

  def list_visible_server_presence_states(_server_id, _user_id), do: []

  def list_room_presence_states(conversation_id) when is_integer(conversation_id) do
    room_presence_states_query(conversation_id)
    |> Repo.all()
    |> normalize_presence_states()
  end

  def list_room_presence_states(_conversation_id), do: []

  def list_visible_room_presence_states(conversation_id, user_id)
      when is_integer(conversation_id) and is_integer(user_id) do
    if viewer_can_access_conversation?(conversation_id, user_id) do
      room_presence_states_query(conversation_id)
      |> Repo.all()
      |> normalize_presence_states()
    else
      []
    end
  end

  def list_visible_room_presence_states(_conversation_id, _user_id), do: []

  def list_peer_controls do
    PeerPolicies.list_peer_controls(Runtime.configured_peers(), discovered_peer_controls())
  end

  def paginate_peer_controls(search_query, page, per_page) do
    configured_peers = Runtime.configured_peers()
    filtered_configured_peers = filter_configured_peers(configured_peers, search_query)

    domains =
      filtered_configured_peers
      |> Enum.map(&String.downcase(&1.domain))
      |> Enum.concat(Discovery.list_discovered_peer_domains(search_query))
      |> Enum.concat(PeerPolicies.list_policy_domains(search_query))
      |> Enum.uniq()
      |> Enum.sort()

    total_count = length(domains)
    total_pages = total_pages(total_count, per_page)
    safe_page = clamp_page(page, total_pages)
    offset = (safe_page - 1) * per_page
    page_domains = Enum.slice(domains, offset, per_page)

    {policy_overrides, users_by_id} =
      PeerPolicies.list_policy_overrides(domains: page_domains, include_users: true)

    discovered_controls =
      Discovery.list_discovered_peer_controls(discovery_context(), domains: page_domains)

    page_entries =
      filtered_configured_peers
      |> Enum.filter(fn peer -> String.downcase(peer.domain) in page_domains end)
      |> PeerPolicies.build_peer_controls(discovered_controls, policy_overrides, users_by_id)

    %{
      entries: page_entries,
      page: safe_page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      stats: peer_control_stats(configured_peers)
    }
  end

  def upsert_peer_policy(domain, attrs, updated_by_id \\ nil) when is_map(attrs) do
    PeerPolicies.upsert_peer_policy(domain, attrs, updated_by_id)
  end

  def clear_peer_policy(domain), do: PeerPolicies.clear_peer_policy(domain)

  def block_peer_domain(domain, reason \\ nil, updated_by_id \\ nil) do
    PeerPolicies.block_peer_domain(domain, reason, updated_by_id)
  end

  def unblock_peer_domain(domain, updated_by_id \\ nil) do
    PeerPolicies.unblock_peer_domain(domain, updated_by_id)
  end

  def resolve_peer(domain) when is_binary(domain) do
    Discovery.resolve_peer(domain, discovery_context())
  end

  def resolve_peer(_domain), do: nil

  defp discovered_peer_controls do
    Discovery.discovered_peer_controls(discovery_context())
  end

  defp discovery_context do
    Contexts.discovery(%{
      peers: &peers/0,
      truncate: &Utils.truncate/1
    })
  end

  defp peer_control_stats(configured_peers) do
    discovered_state = Discovery.discovered_peer_state_map()
    policy_overrides = PeerPolicies.list_policy_overrides()

    PeerPolicies.control_stats(configured_peers, discovered_state, policy_overrides)
  end

  defp filter_configured_peers(configured_peers, search_query)
       when is_list(configured_peers) and is_binary(search_query) do
    case String.trim(search_query) do
      "" ->
        configured_peers

      trimmed ->
        needle = String.downcase(trimmed)

        Enum.filter(configured_peers, fn peer ->
          String.contains?(String.downcase(peer.domain), needle)
        end)
    end
  end

  defp filter_configured_peers(configured_peers, _search_query) when is_list(configured_peers),
    do: configured_peers

  defp server_presence_states_query(server_id, viewer_user_id \\ nil)
       when is_integer(server_id) do
    query =
      from(state in FederationAccountPresenceState,
        join: actor in ActivityPubActor,
        on: actor.id == state.remote_actor_id,
        join: membership in FederationMembershipState,
        on: membership.remote_actor_id == state.remote_actor_id and membership.state == "active",
        join: conversation in ChatConversation,
        on:
          conversation.id == membership.conversation_id and conversation.server_id == ^server_id,
        join: follow in Follow,
        on:
          follow.remote_actor_id == state.remote_actor_id and is_nil(follow.followed_id) and
            follow.pending == false,
        distinct: actor.id,
        order_by: [desc: state.updated_at_remote],
        select: %{
          remote_actor_id: actor.id,
          username: actor.username,
          display_name: actor.display_name,
          domain: actor.domain,
          avatar_url: actor.avatar_url,
          status: state.status,
          activities: state.activities,
          updated_at: state.updated_at_remote,
          expires_at: state.expires_at_remote
        }
      )

    case viewer_user_id do
      user_id when is_integer(user_id) ->
        from([_state, _actor, _membership, _conversation, follow] in query,
          where: follow.follower_id == ^user_id
        )

      _ ->
        query
    end
  end

  defp room_presence_states_query(conversation_id) when is_integer(conversation_id) do
    from(state in FederationRoomPresenceState,
      join: actor in ActivityPubActor,
      on: actor.id == state.remote_actor_id,
      join: membership in FederationMembershipState,
      on:
        membership.remote_actor_id == state.remote_actor_id and
          membership.conversation_id == state.conversation_id and membership.state == "active",
      where: state.conversation_id == ^conversation_id,
      distinct: actor.id,
      order_by: [desc: state.updated_at_remote],
      select: %{
        remote_actor_id: actor.id,
        username: actor.username,
        display_name: actor.display_name,
        domain: actor.domain,
        avatar_url: actor.avatar_url,
        status: state.status,
        activities: state.activities,
        updated_at: state.updated_at_remote,
        expires_at: state.expires_at_remote
      }
    )
  end

  defp normalize_presence_states(states) when is_list(states) do
    Enum.map(states, fn state ->
      effective_status =
        if State.expired_presence_state?(state.expires_at) and state.status != "offline" do
          "offline"
        else
          state.status
        end

      %{
        remote_actor_id: state.remote_actor_id,
        handle: "@#{state.username}@#{state.domain}",
        label:
          case normalize_optional_string(state.display_name) do
            nil -> "@#{state.username}@#{state.domain}"
            display_name -> "#{display_name} (@#{state.username}@#{state.domain})"
          end,
        avatar_url: state.avatar_url,
        status: effective_status,
        activities: State.normalize_presence_activities(state.activities),
        updated_at: state.updated_at,
        expires_at: state.expires_at
      }
    end)
  end

  defp normalize_presence_states(_states), do: []

  defp viewer_can_access_conversation?(conversation_id, user_id)
       when is_integer(conversation_id) and is_integer(user_id) do
    from(conversation in ChatConversation,
      join: membership in assoc(conversation, :members),
      on: membership.user_id == ^user_id and is_nil(membership.left_at),
      where: conversation.id == ^conversation_id,
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.==(1)
  end

  defp viewer_can_access_conversation?(_conversation_id, _user_id), do: false

  defp total_pages(total_count, per_page) when total_count > 0 and per_page > 0 do
    div(total_count + per_page - 1, per_page)
  end

  defp total_pages(_, _), do: 1

  defp clamp_page(page, _total_pages) when page < 1, do: 1
  defp clamp_page(page, total_pages) when page > total_pages, do: total_pages
  defp clamp_page(page, _total_pages), do: page

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil
end
