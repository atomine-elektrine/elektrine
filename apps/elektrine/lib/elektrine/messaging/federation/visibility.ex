defmodule Elektrine.Messaging.Federation.Visibility do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{
    Conversation,
    FederationInviteState,
    FederationMembershipState,
    Server
  }

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo

  @snapshot_invite_states ["pending", "accepted"]
  @active_membership_state "active"
  @room_replay_event_types [
    "message.create",
    "message.update",
    "message.delete",
    "reaction.add",
    "reaction.remove",
    "read.cursor",
    "membership.upsert",
    "role.upsert",
    "role.assignment.upsert",
    "permission.overwrite.upsert",
    "thread.upsert",
    "thread.archive",
    "moderation.action.recorded"
  ]

  def public_bootstrap_channels(%Server{} = server) do
    from(c in Conversation,
      where:
        c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true and
          c.is_public == true,
      order_by: [asc: c.channel_position, asc: c.inserted_at]
    )
    |> Repo.all()
  end

  def public_bootstrap_channels(_server), do: []

  def visible_channels_for_peer(%Server{} = server, peer_or_domain) do
    peer_domain = normalize_peer_domain(peer_or_domain)

    channels =
      from(c in Conversation,
        where:
          c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
        order_by: [asc: c.channel_position, asc: c.inserted_at]
      )
      |> Repo.all()

    case peer_domain do
      nil ->
        channels

      _ ->
        visible_channel_ids =
          snapshot_visible_channel_ids(Enum.map(channels, & &1.id), peer_domain)
          |> MapSet.new()

        Enum.filter(channels, fn channel ->
          public_channel?(server, channel) or MapSet.member?(visible_channel_ids, channel.id)
        end)
    end
  end

  def visible_channels_for_peer(_server, _peer_or_domain), do: []

  def target_domains_for_room(%Conversation{} = conversation) do
    conversation = maybe_preload_server(conversation)

    case conversation.server do
      %Server{is_federated_mirror: true, origin_domain: origin_domain}
      when is_binary(origin_domain) ->
        (active_membership_origin_domains(conversation.id) ++ [normalize_domain(origin_domain)])
        |> Enum.reject(&(is_nil(&1) or &1 == local_domain()))
        |> Enum.uniq()

      %Server{} ->
        active_membership_origin_domains(conversation.id)
        |> Enum.reject(&(is_nil(&1) or &1 == local_domain()))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  def target_domains_for_room(_conversation), do: []

  def target_domains_for_invite(%Conversation{} = conversation, target_payload) do
    (target_domains_for_room(conversation) ++ List.wrap(target_actor_domain(target_payload)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def target_domains_for_invite(_conversation, _target_payload), do: []

  def target_domains_for_event(%{"event_type" => event_type, "payload" => payload})
      when is_binary(event_type) and is_map(payload) do
    case normalized_event_name(event_type) do
      event_type
      when event_type in [
             "message.create",
             "message.update",
             "message.delete",
             "reaction.add",
             "reaction.remove",
             "read.cursor",
             "membership.upsert",
             "role.upsert",
             "role.assignment.upsert",
             "permission.overwrite.upsert",
             "thread.upsert",
             "thread.archive",
             "moderation.action.recorded",
             "typing.start",
             "typing.stop"
           ] ->
        case conversation_for_event_payload(payload) do
          %Conversation{} = conversation -> target_domains_for_room(conversation)
          _ -> nil
        end

      "invite.upsert" ->
        with %Conversation{} = conversation <- conversation_for_event_payload(payload),
             %{} = invite_payload <- payload["invite"] do
          target_domains_for_invite(conversation, invite_payload["target"])
        else
          _ -> nil
        end

      "ban.upsert" ->
        with %Conversation{} = conversation <- conversation_for_event_payload(payload),
             %{} = ban_payload <- payload["ban"] do
          target_domains_for_invite(conversation, ban_payload["target"])
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def target_domains_for_event(_event), do: nil

  def visible_stream_events_query(stream_id, peer_or_domain) when is_binary(stream_id) do
    peer_domain = normalize_peer_domain(peer_or_domain)

    case peer_domain do
      nil ->
        nil

      domain ->
        replay_visibility_filter(stream_id, domain)
    end
  end

  def visible_stream_events_query(_stream_id, _peer_or_domain), do: nil

  def conversation_for_event_payload(payload) when is_map(payload) do
    case event_channel_id(payload) do
      channel_id when is_binary(channel_id) -> conversation_for_channel_id(channel_id)
      _ -> nil
    end
  end

  def conversation_for_event_payload(_payload), do: nil

  def conversation_for_channel_id(channel_id) when is_binary(channel_id) do
    case Repo.get_by(Conversation, type: "channel", federated_source: channel_id) do
      %Conversation{} = conversation ->
        maybe_preload_server(conversation)

      nil ->
        case local_channel_id_from_federation_id(channel_id) do
          conversation_id when is_integer(conversation_id) ->
            case Repo.get(Conversation, conversation_id) do
              %Conversation{type: "channel"} = conversation -> maybe_preload_server(conversation)
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  def conversation_for_channel_id(_channel_id), do: nil

  def public_channel?(%Server{} = server, %Conversation{} = channel) do
    server.is_public == true and channel.is_public == true
  end

  def public_channel?(_server, _channel), do: false

  defp replay_visibility_filter(stream_id, peer_domain)
       when is_binary(stream_id) and is_binary(peer_domain) do
    row_targeted = dynamic([o], fragment("? = ANY(?)", ^peer_domain, o.target_domains))

    case replay_room_visible?(stream_id, peer_domain) do
      true ->
        dynamic(
          [o],
          ^row_targeted or o.event_type in ^room_replay_event_types()
        )

      false ->
        row_targeted
    end
  end

  defp replay_visibility_filter(_stream_id, peer_domain) when is_binary(peer_domain) do
    dynamic([o], fragment("? = ANY(?)", ^peer_domain, o.target_domains))
  end

  defp replay_visibility_filter(_stream_id, _peer_domain), do: nil

  defp replay_room_visible?(stream_id, peer_domain)
       when is_binary(stream_id) and is_binary(peer_domain) do
    with "channel:" <> channel_id <- stream_id,
         %Conversation{} = conversation <- conversation_for_channel_id(channel_id),
         %Server{} = server <- conversation.server do
      public_channel?(server, conversation) or
        conversation.id in snapshot_visible_channel_ids([conversation.id], peer_domain)
    else
      _ -> false
    end
  end

  defp replay_room_visible?(_stream_id, _peer_domain), do: false

  defp active_membership_origin_domains(conversation_id) when is_integer(conversation_id) do
    from(state in FederationMembershipState,
      where:
        state.conversation_id == ^conversation_id and state.state == ^@active_membership_state,
      select: state.origin_domain,
      distinct: true
    )
    |> Repo.all()
    |> Enum.map(&normalize_domain/1)
    |> Enum.reject(&is_nil/1)
  end

  defp active_membership_origin_domains(_conversation_id), do: []

  defp snapshot_visible_channel_ids([], _peer_domain), do: []

  defp snapshot_visible_channel_ids(channel_ids, peer_domain) when is_binary(peer_domain) do
    banned_targets =
      banned_target_uris(channel_ids, peer_domain)
      |> MapSet.new()

    membership_ids =
      from(state in FederationMembershipState,
        where:
          state.conversation_id in ^channel_ids and state.state == ^@active_membership_state and
            state.origin_domain == ^peer_domain,
        select: state.conversation_id,
        distinct: true
      )
      |> Repo.all()

    invite_ids =
      from(invite in FederationInviteState,
        where:
          invite.conversation_id in ^channel_ids and invite.state in ^@snapshot_invite_states,
        select: {invite.conversation_id, invite.target_payload, invite.target_uri}
      )
      |> Repo.all()
      |> Enum.reduce([], fn {conversation_id, target_payload, target_uri}, acc ->
        normalized_target_uri = normalize_optional_string(target_uri)

        if target_domain_matches?(target_payload, target_uri, peer_domain) and
             not MapSet.member?(banned_targets, {conversation_id, normalized_target_uri}) do
          [conversation_id | acc]
        else
          acc
        end
      end)

    membership_ids ++ invite_ids
  end

  defp snapshot_visible_channel_ids(_channel_ids, _peer_domain), do: []

  defp banned_target_uris(channel_ids, peer_domain)
       when is_list(channel_ids) and is_binary(peer_domain) do
    from(state in FederationMembershipState,
      join: actor in Actor,
      on: actor.id == state.remote_actor_id,
      where: state.conversation_id in ^channel_ids and state.state == "banned",
      where: actor.domain == ^peer_domain,
      select: {state.conversation_id, actor.uri},
      distinct: true
    )
    |> Repo.all()
    |> Enum.map(fn {conversation_id, actor_uri} ->
      {conversation_id, normalize_optional_string(actor_uri)}
    end)
  end

  defp banned_target_uris(_channel_ids, _peer_domain), do: []

  defp target_actor_domain(%{} = target_payload) do
    normalize_peer_domain(
      target_payload["domain"] || target_payload[:domain] || target_payload["uri"] ||
        target_payload[:uri] || target_payload["id"] || target_payload[:id]
    )
  end

  defp target_actor_domain(value) when is_binary(value), do: normalize_peer_domain(value)
  defp target_actor_domain(_value), do: nil

  defp target_domain_matches?(target_payload, target_uri, peer_domain)
       when is_map(target_payload) and is_binary(peer_domain) do
    target_domain =
      target_actor_domain(target_payload) ||
        normalize_peer_domain(target_uri)

    target_domain == peer_domain
  end

  defp target_domain_matches?(_target_payload, _target_uri, _peer_domain), do: false

  defp event_channel_id(payload) when is_map(payload) do
    refs = payload["refs"] || %{}
    get_in(payload, ["channel", "id"]) || refs["channel_id"]
  end

  defp event_channel_id(_payload), do: nil

  defp local_channel_id_from_federation_id(channel_id) when is_binary(channel_id) do
    with %URI{host: host, path: path} <- URI.parse(channel_id),
         true <- normalize_domain(host) == local_domain(),
         ["", "_arblarg", "channels", local_id] <- String.split(path || "", "/"),
         {parsed_id, ""} <- Integer.parse(local_id) do
      parsed_id
    else
      _ -> nil
    end
  end

  defp local_channel_id_from_federation_id(_channel_id), do: nil

  defp maybe_preload_server(%Conversation{server: %Server{}} = conversation), do: conversation

  defp maybe_preload_server(%Conversation{} = conversation),
    do: Repo.preload(conversation, :server)

  defp maybe_preload_server(conversation), do: conversation

  defp canonical_event_type(event_type),
    do: Elektrine.Messaging.ArblargSDK.canonical_event_type(event_type)

  defp normalized_event_name(event_type) when is_binary(event_type) do
    canonical = canonical_event_type(event_type)
    Map.get(Elektrine.Messaging.ArblargSDK.schema_bindings(), canonical, canonical)
  end

  defp normalized_event_name(event_type), do: event_type

  defp room_replay_event_types do
    canonical_room_replay_event_types =
      Enum.map(@room_replay_event_types, &canonical_event_type/1)

    @room_replay_event_types ++ canonical_room_replay_event_types
  end

  defp local_domain do
    Elektrine.Messaging.Federation.local_domain()
    |> normalize_domain()
  end

  defp normalize_peer_domain(%{} = peer) do
    normalize_peer_domain(peer[:domain] || peer["domain"])
  end

  defp normalize_peer_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case URI.parse(trimmed) do
          %URI{host: host} when is_binary(host) and host != "" -> normalize_domain(host)
          _ -> normalize_domain(trimmed)
        end
    end
  end

  defp normalize_peer_domain(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_domain(_value), do: nil
end
