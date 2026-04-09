defmodule Elektrine.Messaging.Federation.Snapshots do
  @moduledoc false

  import Ecto.Query, warn: false

  import Elektrine.Messaging.Federation.Utils,
    only: [infer_room_origin_domain: 1, message_federation_id: 1]

  require Logger

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Messaging.ArblargSDK

  alias Elektrine.Messaging.{
    ChatConversation,
    ChatConversationMember,
    ChatMessage,
    ChatMessageReaction,
    CommunityBan,
    FederationExtensionEvent,
    FederationInviteState,
    FederationMembershipState,
    FederationOutboxEvent,
    FederationReadCursor,
    FederationSessionClient,
    FederationStreamPosition,
    Server
  }

  alias Elektrine.Messaging.Federation.Visibility
  alias Elektrine.Repo

  def build_server_snapshot(server_id, opts, context)
      when is_integer(server_id) and is_list(opts) and is_map(context) do
    messages_per_channel =
      call(context, :parse_int, [Keyword.get(opts, :messages_per_channel, 25), 25])
      |> max(1)
      |> min(250)

    peer = Keyword.get(opts, :peer)

    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        case peer do
          nil ->
            from(c in ChatConversation,
              where:
                c.server_id == ^server.id and c.type == "channel" and
                  c.is_federated_mirror != true,
              order_by: [asc: c.channel_position, asc: c.inserted_at]
            )
            |> Repo.all()

          _ ->
            Visibility.visible_channels_for_peer(server, peer)
        end
        |> Enum.take(call(context, :snapshot_channel_limit, []))

      if channels != [] or is_nil(peer) or server.is_public == true do
        channel_payloads = Enum.map(channels, &call(context, :channel_payload, [&1]))

        channel_messages =
          Enum.flat_map(channels, fn channel ->
            from(m in ChatMessage,
              where: m.conversation_id == ^channel.id and is_nil(m.deleted_at),
              order_by: [desc: m.inserted_at],
              limit: ^messages_per_channel,
              preload: [:sender]
            )
            |> Repo.all()
            |> Enum.reverse()
            |> ChatMessage.decrypt_messages()
            |> Enum.map(fn message -> call(context, :message_payload, [message, channel]) end)
          end)
          |> Enum.take(call(context, :snapshot_message_limit, []))

        unsigned = %{
          "version" => 1,
          "origin_domain" => call(context, :local_domain, []),
          "server" => call(context, :server_payload, [server]),
          "channels" => channel_payloads,
          "messages" => channel_messages,
          "governance" => snapshot_governance_payload(server, channels, context),
          "message_deletions" => snapshot_message_deletions(server, channels, context),
          "reactions" => snapshot_reaction_payloads(server, channels, context),
          "read_cursors" => snapshot_read_cursor_payloads(server, channels, context),
          "extensions" => snapshot_extension_payloads(server, channels, peer, context),
          "stream_positions" => snapshot_stream_positions(server, channels, context)
        }

        {:ok, sign_snapshot_payload(unsigned, context)}
      else
        {:error, :not_authorized}
      end
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  def import_server_snapshot(payload, remote_domain, context)
      when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    with :ok <- call(context, :validate_snapshot_payload, [payload, remote_domain]) do
      Repo.transaction(fn ->
        with {:ok, mirror_server} <-
               call(context, :upsert_mirror_server, [payload["server"], remote_domain]),
             {:ok, channel_map} <-
               call(context, :upsert_mirror_channels, [mirror_server, payload["channels"] || []]),
             :ok <-
               call(context, :upsert_mirror_messages, [
                 channel_map,
                 payload["messages"] || [],
                 remote_domain
               ]),
             :ok <-
               import_snapshot_governance(
                 channel_map,
                 payload["governance"] || %{},
                 remote_domain,
                 context
               ),
             :ok <-
               import_snapshot_extensions(
                 payload["extensions"] || [],
                 remote_domain,
                 context
               ),
             :ok <-
               import_snapshot_message_deletions(
                 payload["message_deletions"] || [],
                 remote_domain,
                 context
               ),
             :ok <-
               import_snapshot_reactions(payload["reactions"] || [], remote_domain, context),
             :ok <-
               import_snapshot_read_cursors(
                 payload["read_cursors"] || [],
                 remote_domain,
                 context
               ),
             :ok <-
               store_snapshot_stream_positions(
                 payload["stream_positions"] || [],
                 remote_domain,
                 context
               ) do
          {:ok, mirror_server}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {:ok, server}} -> {:ok, server}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def export_stream_events(stream_id, opts, context)
      when is_binary(stream_id) and is_list(opts) and is_map(context) do
    after_sequence =
      call(context, :parse_int, [Keyword.get(opts, :after_sequence, 0), 0]) |> max(0)

    limit =
      call(context, :parse_int, [
        Keyword.get(opts, :limit, call(context, :stream_replay_limit, [])),
        call(context, :stream_replay_limit, [])
      ])

    bounded_limit = limit |> max(1) |> min(call(context, :stream_replay_limit, []))
    peer = Keyword.get(opts, :peer)
    visible_filter = Visibility.visible_stream_events_query(stream_id, peer)

    base_events_query =
      from(o in FederationOutboxEvent,
        where: o.stream_id == ^stream_id and o.sequence > ^after_sequence,
        order_by: [asc: o.sequence, asc: o.id],
        limit: ^bounded_limit,
        select: %{sequence: o.sequence, payload: o.payload}
      )
      |> maybe_filter_visible_stream_events(visible_filter)

    events = Repo.all(base_events_query)

    last_sequence =
      from(o in FederationOutboxEvent,
        where: o.stream_id == ^stream_id,
        select: max(o.sequence)
      )
      |> maybe_filter_visible_stream_events(visible_filter)
      |> Repo.one()
      |> case do
        nil -> after_sequence
        sequence -> sequence
      end

    next_after_sequence =
      case List.last(events) do
        %{sequence: sequence} -> sequence
        _ -> after_sequence
      end

    %{
      "version" => 1,
      "stream_id" => stream_id,
      "after_sequence" => after_sequence,
      "next_after_sequence" => next_after_sequence,
      "last_sequence" => last_sequence,
      "has_more" => next_after_sequence < last_sequence,
      "events" => Enum.map(events, & &1.payload)
    }
  end

  def recover_sequence_gap(payload, remote_domain, context)
      when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    with %{} = peer <- call(context, :incoming_peer, [remote_domain]),
         stream_id when is_binary(stream_id) <- payload["stream_id"] do
      case recover_sequence_gap_via_stream(peer, remote_domain, stream_id, context) do
        :ok ->
          case call(context, :receive_event, [payload, remote_domain]) do
            {:ok, result} when result in [:applied, :duplicate, :stale] ->
              {:ok, :recovered_via_stream}

            {:error, reason} ->
              recover_sequence_gap_via_snapshot(payload, remote_domain, peer, reason, context)
          end

        {:error, _reason} ->
          recover_sequence_gap_via_snapshot(
            payload,
            remote_domain,
            peer,
            :stream_recovery_failed,
            context
          )
      end
    else
      nil -> {:error, :unknown_peer}
      _ -> {:error, :recovery_failed}
    end
  end

  def refresh_mirror_server_snapshot(%Server{} = server, context) when is_map(context) do
    with true <- server.is_federated_mirror == true,
         remote_domain when is_binary(remote_domain) <-
           call(context, :normalize_optional_string, [server.origin_domain]),
         {:ok, remote_server_id} <-
           call(context, :infer_remote_server_id_from_federation_id, [server.federation_id]),
         %{} = peer <-
           call(context, :outgoing_peer, [remote_domain]) ||
             call(context, :incoming_peer, [remote_domain]),
         {:ok, snapshot_payload} <- fetch_remote_snapshot(peer, remote_server_id, context) do
      import_server_snapshot(snapshot_payload, remote_domain, context)
    else
      false -> {:error, :not_federated_mirror}
      nil -> {:error, :unknown_peer}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :cannot_infer_snapshot_server_id}
    end
  end

  def refresh_mirror_server_snapshot(_server, _context), do: {:error, :not_federated_mirror}

  def push_snapshot_to_peer(peer, snapshot, context) when is_map(context) do
    path = "/_arblarg/sync"
    url = call(context, :outbound_sync_url, [peer])
    body = Jason.encode!(snapshot)
    headers = call(context, :signed_headers, [peer, "POST", path, "", body])
    request = Finch.build(:post, url, headers, body)

    case SafeFetch.request(request, Elektrine.Finch,
           receive_timeout: call(context, :delivery_timeout_ms, []),
           pool_timeout: 5000
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning(
          "Messaging federation sync failed for #{peer.domain}: HTTP #{status} #{call(context, :truncate, [response_body])}"
        )

      {:error, reason} ->
        Logger.warning(
          "Messaging federation sync transport error for #{peer.domain}: #{inspect(reason)}"
        )
    end
  end

  def snapshot_governance_entries(governance, context)
      when is_map(governance) and is_map(context) do
    memberships =
      governance
      |> Map.get("memberships", [])
      |> List.wrap()
      |> Enum.map(&{"membership.upsert", &1})

    invites =
      governance
      |> Map.get("invites", [])
      |> List.wrap()
      |> Enum.map(&{"invite.upsert", &1})

    bans =
      governance
      |> Map.get("bans", [])
      |> List.wrap()
      |> Enum.map(&{"ban.upsert", &1})

    (memberships ++ invites ++ bans)
    |> Enum.take(call(context, :snapshot_governance_limit, []))
  end

  def snapshot_governance_entries(_governance, _context), do: []

  def snapshot_signature_payload(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.delete("signature")
    |> ArblargSDK.canonical_json_payload()
  end

  def snapshot_signature_payload(_snapshot), do: ""

  defp snapshot_stream_positions(%Server{} = server, channels, context) when is_list(channels) do
    stream_ids =
      [
        call(context, :server_stream_id, [server.id])
        | Enum.map(channels, &call(context, :channel_stream_id, [&1.id]))
      ]

    stream_ids = Enum.uniq(stream_ids)
    local_origin_domain = call(context, :local_domain, [])

    local_positions =
      Enum.map(stream_ids, fn stream_id ->
        %{
          "origin_domain" => local_origin_domain,
          "stream_id" => stream_id,
          "last_sequence" => local_last_sequence_for_stream(stream_id)
        }
      end)

    remote_positions =
      from(position in FederationStreamPosition,
        where: position.stream_id in ^stream_ids,
        select: %{
          origin_domain: position.origin_domain,
          stream_id: position.stream_id,
          last_sequence: position.last_sequence
        }
      )
      |> Repo.all()
      |> Enum.reject(fn %{origin_domain: origin_domain} ->
        String.downcase(to_string(origin_domain || "")) ==
          String.downcase(to_string(local_origin_domain || ""))
      end)
      |> Enum.map(fn position ->
        %{
          "origin_domain" => position.origin_domain,
          "stream_id" => position.stream_id,
          "last_sequence" => position.last_sequence
        }
      end)

    local_positions ++ remote_positions
  end

  defp snapshot_stream_positions(_server, _channels, _context), do: []

  defp snapshot_governance_payload(%Server{} = server, channels, context)
       when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)
    channel_index = Map.new(channels, &{&1.id, &1})

    memberships =
      (local_membership_payloads(server, channel_index, context) ++
         remote_membership_payloads(server, channel_index, context))
      |> Enum.take(call(context, :snapshot_governance_limit, []))

    remaining_governance_slots =
      max(call(context, :snapshot_governance_limit, []) - length(memberships), 0)

    invites =
      from(invite in FederationInviteState,
        where: invite.conversation_id in ^channel_ids,
        order_by: [asc: invite.conversation_id, asc: invite.target_uri]
      )
      |> Repo.all()
      |> Enum.take(remaining_governance_slots)
      |> Enum.reduce([], fn invite, acc ->
        with %ChatConversation{} = indexed_channel <-
               Map.get(channel_index, invite.conversation_id),
             actor when is_map(actor) <- invite.actor_payload,
             target when is_map(target) <- invite.target_payload do
          payload = %{
            "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
            "invite" => %{
              "actor" => actor,
              "target" => target,
              "role" => invite.role,
              "state" => invite.state,
              "invited_at" => call(context, :maybe_iso8601, [invite.invited_at_remote]),
              "updated_at" => call(context, :maybe_iso8601, [invite.updated_at_remote]),
              "metadata" => invite.metadata || %{}
            }
          }

          acc ++ [payload]
        else
          _ -> acc
        end
      end)

    remaining_governance_slots =
      max(remaining_governance_slots - length(invites), 0)

    bans =
      (local_ban_payloads(server, channel_ids, channel_index, context) ++
         federated_ban_payloads(server, channel_ids, channel_index, context))
      |> Enum.uniq_by(fn payload ->
        {
          get_in(payload, ["refs", "channel_id"]),
          get_in(payload, ["ban", "target", "uri"]) || get_in(payload, ["ban", "target", "id"])
        }
      end)
      |> Enum.take(remaining_governance_slots)

    %{"memberships" => memberships, "invites" => invites, "bans" => bans}
  end

  defp snapshot_governance_payload(_server, _channels, _context),
    do: %{"memberships" => [], "invites" => [], "bans" => []}

  defp local_membership_payloads(%Server{} = server, channel_index, context)
       when is_map(channel_index) and is_map(context) do
    from(member in ChatConversationMember,
      where: member.conversation_id in ^Map.keys(channel_index),
      preload: [:user, :conversation],
      order_by: [asc: member.conversation_id, asc: member.user_id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn member, acc ->
      with %User{} = user <- member.user,
           %ChatConversation{} = conversation <- member.conversation,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, conversation.id) do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "membership" => %{
            "actor" => call(context, :sender_payload, [user]),
            "role" => member.role || "member",
            "state" => if(is_nil(member.left_at), do: "active", else: "left"),
            "joined_at" => call(context, :format_created_at, [member.joined_at]),
            "updated_at" => call(context, :format_created_at, [member.updated_at]),
            "metadata" => %{}
          }
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp local_membership_payloads(_server, _channel_index, _context), do: []

  defp remote_membership_payloads(%Server{} = server, channel_index, context)
       when is_map(channel_index) and is_map(context) do
    from(state in FederationMembershipState,
      where: state.conversation_id in ^Map.keys(channel_index),
      where: state.state in ["active", "invited", "left", "banned"],
      preload: [:remote_actor],
      order_by: [asc: state.conversation_id, asc: state.remote_actor_id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn state, acc ->
      with %Elektrine.ActivityPub.Actor{} = actor <- state.remote_actor,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, state.conversation_id) do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "membership" => %{
            "actor" => remote_actor_payload(actor),
            "role" => state.role || "member",
            "state" => state.state || "active",
            "joined_at" => call(context, :maybe_iso8601, [state.joined_at_remote]),
            "updated_at" => call(context, :maybe_iso8601, [state.updated_at_remote]),
            "metadata" => state.metadata || %{}
          }
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp remote_membership_payloads(_server, _channel_index, _context), do: []

  defp local_ban_payloads(%Server{} = server, channel_ids, channel_index, context)
       when is_list(channel_ids) and is_map(channel_index) and is_map(context) do
    from(ban in CommunityBan,
      where: ban.conversation_id in ^channel_ids,
      preload: [:user, :banned_by, :conversation],
      order_by: [asc: ban.conversation_id, asc: ban.user_id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn ban, acc ->
      with %User{} = target_user <- ban.user,
           %ChatConversation{} = conversation <- ban.conversation,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, conversation.id),
           %{} = actor_payload <- ban_actor_payload(ban, context) do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "ban" => %{
            "actor" => actor_payload,
            "target" => call(context, :sender_payload, [target_user]),
            "state" => "active",
            "reason" => call(context, :normalize_optional_string, [ban.reason]),
            "banned_at" =>
              call(context, :maybe_iso8601, [ban.banned_at_remote || ban.inserted_at]),
            "updated_at" =>
              call(context, :maybe_iso8601, [ban.updated_at_remote || ban.updated_at]),
            "expires_at" => call(context, :maybe_iso8601, [ban.expires_at]),
            "metadata" => ban.metadata || %{}
          }
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp local_ban_payloads(_server, _channel_ids, _channel_index, _context), do: []

  defp ban_actor_payload(%CommunityBan{actor_payload: actor_payload}, _context)
       when is_map(actor_payload) and map_size(actor_payload) > 0,
       do: actor_payload

  defp ban_actor_payload(%CommunityBan{banned_by: %User{} = banned_by}, context),
    do: call(context, :sender_payload, [banned_by])

  defp ban_actor_payload(_ban, _context), do: nil

  defp federated_ban_payloads(%Server{} = server, channel_ids, channel_index, context)
       when is_list(channel_ids) and is_map(channel_index) and is_map(context) do
    from(state in FederationMembershipState,
      where: state.conversation_id in ^channel_ids and state.state == "banned",
      preload: [:remote_actor],
      order_by: [asc: state.conversation_id, asc: state.remote_actor_id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn state, acc ->
      metadata = state.metadata || %{}

      with %ActivityPubActor{} = target_actor <- state.remote_actor,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, state.conversation_id),
           %{} = actor_payload <- metadata["actor"] do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "ban" => %{
            "actor" => actor_payload,
            "target" => remote_actor_payload(target_actor),
            "state" => metadata["ban_state"] || "active",
            "reason" => call(context, :normalize_optional_string, [metadata["reason"]]),
            "banned_at" => call(context, :maybe_iso8601, [state.joined_at_remote]),
            "updated_at" => call(context, :maybe_iso8601, [state.updated_at_remote]),
            "expires_at" => call(context, :normalize_optional_string, [metadata["expires_at"]]),
            "metadata" => Map.get(metadata, "metadata", %{})
          }
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp federated_ban_payloads(_server, _channel_ids, _channel_index, _context), do: []

  defp snapshot_message_deletions(%Server{} = server, channels, context) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)
    channel_index = Map.new(channels, &{&1.id, &1})

    from(m in ChatMessage,
      where: m.conversation_id in ^channel_ids and not is_nil(m.deleted_at),
      preload: [:conversation],
      order_by: [desc: m.updated_at, desc: m.id]
    )
    |> Repo.all()
    |> Enum.take(call(context, :snapshot_message_limit, []))
    |> Enum.reduce([], fn message, acc ->
      with %ChatConversation{} = conversation <- message.conversation,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, conversation.id) do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "message_id" => message.federated_source || message_federation_id(message.id),
          "deleted_at" => call(context, :maybe_iso8601, [message.deleted_at])
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp snapshot_message_deletions(_server, _channels, _context), do: []

  defp snapshot_reaction_payloads(%Server{} = server, channels, context) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)
    channel_index = Map.new(channels, &{&1.id, &1})

    local_reaction_payloads(server, channel_ids, channel_index, context) ++
      remote_reaction_payloads(server, channel_ids, channel_index, context)
  end

  defp snapshot_reaction_payloads(_server, _channels, _context), do: []

  defp local_reaction_payloads(%Server{} = server, channel_ids, channel_index, context)
       when is_list(channel_ids) and is_map(channel_index) and is_map(context) do
    from(reaction in ChatMessageReaction,
      join: message in ChatMessage,
      on: reaction.chat_message_id == message.id,
      join: user in User,
      on: reaction.user_id == user.id,
      where: message.conversation_id in ^channel_ids,
      preload: [chat_message: [:conversation], user: []],
      order_by: [asc: reaction.id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn reaction, acc ->
      with %ChatMessage{} = message <- reaction.chat_message,
           %ChatConversation{} = conversation <- message.conversation,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, conversation.id),
           %User{} = user <- reaction.user do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "message_id" => message.federated_source || message_federation_id(message.id),
          "reaction" => %{
            "emoji" => reaction.emoji,
            "actor" => call(context, :sender_payload, [user])
          }
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp local_reaction_payloads(_server, _channel_ids, _channel_index, _context), do: []

  defp remote_reaction_payloads(%Server{} = server, channel_ids, channel_index, context)
       when is_list(channel_ids) and is_map(channel_index) and is_map(context) do
    from(reaction in ChatMessageReaction,
      join: message in ChatMessage,
      on: reaction.chat_message_id == message.id,
      join: actor in ActivityPubActor,
      on: reaction.remote_actor_id == actor.id,
      where: message.conversation_id in ^channel_ids,
      preload: [chat_message: [:conversation], remote_actor: []],
      order_by: [asc: reaction.id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn reaction, acc ->
      with %ChatMessage{} = message <- reaction.chat_message,
           %ChatConversation{} = conversation <- message.conversation,
           %ChatConversation{} = indexed_channel <- Map.get(channel_index, conversation.id),
           %ActivityPubActor{} = actor <- reaction.remote_actor do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
          "message_id" => message.federated_source || message_federation_id(message.id),
          "reaction" => %{
            "emoji" => reaction.emoji,
            "actor" => remote_actor_payload(actor)
          }
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp remote_reaction_payloads(_server, _channel_ids, _channel_index, _context), do: []

  defp snapshot_read_cursor_payloads(%Server{} = server, channels, context)
       when is_list(channels) do
    channel_index = Map.new(channels, &{&1.id, &1})

    local_read_cursor_payloads(server, channel_index, context) ++
      remote_read_cursor_payloads(server, channel_index, context)
  end

  defp snapshot_read_cursor_payloads(_server, _channels, _context), do: []

  defp local_read_cursor_payloads(%Server{} = server, channel_index, context)
       when is_map(channel_index) and is_map(context) do
    from(member in ChatConversationMember,
      where:
        member.conversation_id in ^Map.keys(channel_index) and is_nil(member.left_at) and
          not is_nil(member.last_read_at),
      join: user in User,
      on: member.user_id == user.id,
      preload: [user: []],
      order_by: [asc: member.conversation_id, asc: member.user_id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn member, acc ->
      with %User{} = user <- member.user,
           %ChatConversation{} = channel <- Map.get(channel_index, member.conversation_id),
           %ChatMessage{} = message <- last_read_chat_message(channel.id, member.last_read_at) do
        payload = %{
          "refs" => call(context, :event_refs_payload, [server, channel]),
          "read_through_message_id" =>
            message.federated_source || message_federation_id(message.id),
          "actor" => call(context, :sender_payload, [user]),
          "read_at" => call(context, :maybe_iso8601, [member.last_read_at])
        }

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp local_read_cursor_payloads(_server, _channel_index, _context), do: []

  defp remote_read_cursor_payloads(%Server{} = server, channel_index, context)
       when is_map(channel_index) and is_map(context) do
    from(cursor in FederationReadCursor,
      where: cursor.conversation_id in ^Map.keys(channel_index),
      preload: [:chat_message, :remote_actor],
      order_by: [asc: cursor.conversation_id, asc: cursor.remote_actor_id]
    )
    |> Repo.all()
    |> Enum.reduce([], fn cursor, acc ->
      with %ChatConversation{} = channel <- Map.get(channel_index, cursor.conversation_id),
           %ChatMessage{} = message <- cursor.chat_message,
           %ActivityPubActor{} = actor <- cursor.remote_actor do
        payload =
          %{
            "refs" => call(context, :event_refs_payload, [server, channel]),
            "read_through_message_id" =>
              message.federated_source || message_federation_id(message.id),
            "actor" => remote_actor_payload(actor),
            "read_at" => call(context, :maybe_iso8601, [cursor.read_at])
          }
          |> maybe_put_read_through_sequence(cursor.read_through_sequence)

        acc ++ [payload]
      else
        _ -> acc
      end
    end)
  end

  defp remote_read_cursor_payloads(_server, _channel_index, _context), do: []

  defp snapshot_extension_payloads(%Server{} = server, channels, peer, context)
       when is_list(channels) and is_map(context) do
    channel_ids = Enum.map(channels, & &1.id)

    from(event in FederationExtensionEvent,
      where: event.server_id == ^server.id or event.conversation_id in ^channel_ids,
      order_by: [asc: event.occurred_at, asc: event.id]
    )
    |> Repo.all()
    |> Enum.map(fn event ->
      %{"event_type" => event.event_type, "payload" => event.payload || %{}}
    end)
    |> maybe_filter_snapshot_extensions_for_peer(peer, context)
  end

  defp snapshot_extension_payloads(_server, _channels, _peer, _context), do: []

  defp maybe_filter_snapshot_extensions_for_peer(extensions, %{} = peer, context)
       when is_list(extensions) and is_map(context) do
    Enum.filter(extensions, fn
      %{"event_type" => event_type} when is_binary(event_type) ->
        call(context, :peer_supports_event_type, [peer, event_type])

      _ ->
        false
    end)
  end

  defp maybe_filter_snapshot_extensions_for_peer(extensions, _peer, _context)
       when is_list(extensions),
       do: extensions

  defp import_snapshot_governance(_channel_map, governance, remote_domain, context)
       when is_map(governance) and is_binary(remote_domain) and is_map(context) do
    governance
    |> snapshot_governance_entries(context)
    |> Enum.reduce_while(:ok, fn {event_type, payload}, :ok ->
      case call(context, :validate_snapshot_governance_payload, [
             event_type,
             payload,
             remote_domain
           ]) do
        :ok ->
          case call(context, :apply_event, [event_type, payload, remote_domain]) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp import_snapshot_governance(_channel_map, _governance, _remote_domain, _context),
    do: {:error, :invalid_snapshot_governance}

  defp import_snapshot_message_deletions(message_deletions, remote_domain, context)
       when is_list(message_deletions) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(message_deletions, :ok, fn payload, :ok ->
      case call(context, :apply_event, ["message.delete", payload, remote_domain]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp import_snapshot_message_deletions(_message_deletions, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp import_snapshot_reactions(reactions, remote_domain, context)
       when is_list(reactions) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(reactions, :ok, fn payload, :ok ->
      case call(context, :apply_event, ["reaction.add", payload, remote_domain]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp import_snapshot_reactions(_reactions, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp import_snapshot_read_cursors(read_cursors, remote_domain, context)
       when is_list(read_cursors) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(read_cursors, :ok, fn payload, :ok ->
      case call(context, :apply_event, ["read.cursor", payload, remote_domain]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp import_snapshot_read_cursors(_read_cursors, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp import_snapshot_extensions(extensions, remote_domain, context)
       when is_list(extensions) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(extensions, :ok, fn
      %{"event_type" => event_type, "payload" => payload}, :ok
      when is_binary(event_type) and is_map(payload) ->
        case call(context, :apply_event, [event_type, payload, remote_domain]) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _, :ok ->
        {:halt, {:error, :invalid_payload}}
    end)
  end

  defp import_snapshot_extensions(_extensions, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp remote_actor_payload(%Elektrine.ActivityPub.Actor{} = actor) do
    %{
      "id" => actor.uri,
      "uri" => actor.uri,
      "username" => actor.username,
      "display_name" => actor.display_name || actor.username,
      "domain" => actor.domain,
      "handle" => "#{actor.username}@#{actor.domain}"
    }
  end

  defp remote_actor_payload(_actor), do: nil

  defp maybe_put_read_through_sequence(payload, sequence)
       when is_map(payload) and is_integer(sequence) and sequence > 0 do
    Map.put(payload, "read_through_sequence", sequence)
  end

  defp maybe_put_read_through_sequence(payload, _sequence) when is_map(payload), do: payload

  defp sign_snapshot_payload(snapshot, context) when is_map(snapshot) do
    {key_id, private_key} = call(context, :local_event_signing_material, [])

    Map.put(snapshot, "signature", %{
      "algorithm" => ArblargSDK.signature_algorithm(),
      "key_id" => key_id,
      "value" =>
        snapshot
        |> snapshot_signature_payload()
        |> ArblargSDK.sign_payload(private_key)
    })
  end

  defp sign_snapshot_payload(snapshot, _context), do: snapshot

  defp local_last_sequence_for_stream(stream_id) when is_binary(stream_id) do
    from(o in FederationOutboxEvent,
      where: o.stream_id == ^stream_id,
      select: max(o.sequence)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      sequence -> sequence
    end
  end

  defp local_last_sequence_for_stream(_stream_id), do: 0

  defp store_snapshot_stream_positions(stream_positions, remote_domain, context)
       when is_list(stream_positions) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(stream_positions, :ok, fn position, :ok ->
      position_origin_domain =
        call(context, :normalize_optional_string, [
          position["origin_domain"] || position[:origin_domain] || remote_domain
        ])

      stream_id =
        call(context, :normalize_optional_string, [position["stream_id"] || position[:stream_id]])

      last_sequence =
        call(context, :parse_int, [position["last_sequence"] || position[:last_sequence], -1])

      cond do
        !is_binary(position_origin_domain) ->
          {:halt, {:error, :invalid_snapshot_stream_positions}}

        !is_binary(stream_id) ->
          {:halt, {:error, :invalid_snapshot_stream_positions}}

        last_sequence < 0 ->
          {:halt, {:error, :invalid_snapshot_stream_positions}}

        last_sequence > current_stream_sequence(position_origin_domain, stream_id) ->
          call(context, :store_stream_position, [position_origin_domain, stream_id, last_sequence])

          {:cont, :ok}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp store_snapshot_stream_positions(_stream_positions, _remote_domain, _context),
    do: {:error, :invalid_snapshot_stream_positions}

  defp maybe_filter_visible_stream_events(query, nil), do: query

  defp maybe_filter_visible_stream_events(query, visible_filter) do
    from(row in query, where: ^visible_filter)
  end

  defp fetch_remote_snapshot(peer, remote_server_id, context)
       when is_integer(remote_server_id) and is_map(context) do
    if call(context, :peer_supports, [peer, "session_transport", false]) &&
         is_binary(call(context, :outbound_session_websocket_url, [peer])) do
      case FederationSessionClient.send_request(
             peer,
             "snapshot",
             %{"server_id" => remote_server_id},
             timeout: call(context, :delivery_timeout_ms, [])
           ) do
        {:ok, %{} = payload} ->
          {:ok, payload}

        {:error, :snapshot_unavailable} ->
          {:error, :snapshot_unavailable}

        {:error, _reason} ->
          fetch_remote_snapshot_over_http(peer, remote_server_id, context)
      end
    else
      fetch_remote_snapshot_over_http(peer, remote_server_id, context)
    end
  end

  defp fetch_remote_snapshot_over_http(peer, remote_server_id, context)
       when is_integer(remote_server_id) and is_map(context) do
    path = "/_arblarg/servers/#{remote_server_id}/snapshot"
    url = call(context, :outbound_snapshot_url, [peer, remote_server_id])
    headers = call(context, :signed_headers, [peer, "GET", path, "", ""])
    request = Finch.build(:get, url, headers)

    case SafeFetch.request(request, Elektrine.Finch,
           receive_timeout: call(context, :delivery_timeout_ms, []),
           pool_timeout: 5000
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} -> {:ok, payload}
          _ -> {:error, :invalid_snapshot_response}
        end

      {:ok, %Finch.Response{status: status}} when status in [404, 422] ->
        {:error, :snapshot_unavailable}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, call(context, :truncate, [body])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recover_sequence_gap_via_stream(peer, remote_domain, stream_id, context)
       when is_binary(remote_domain) and is_binary(stream_id) and is_map(context) do
    after_sequence = current_stream_sequence(remote_domain, stream_id)

    recover_stream_replay_pages(peer, remote_domain, stream_id, after_sequence, context)
  end

  defp recover_sequence_gap_via_snapshot(payload, remote_domain, peer, reason, context)
       when is_binary(remote_domain) and is_map(context) do
    snapshot_remote_domain = snapshot_recovery_domain(payload, remote_domain, context)
    snapshot_peer = snapshot_recovery_peer(snapshot_remote_domain, peer, context)

    with {:ok, remote_server_id} <- call(context, :infer_remote_server_id, [payload]),
         %{} = snapshot_peer <- snapshot_peer,
         {:ok, snapshot_payload} <-
           fetch_remote_snapshot(snapshot_peer, remote_server_id, context),
         {:ok, _mirror_server} <-
           import_server_snapshot(snapshot_payload, snapshot_remote_domain, context) do
      case call(context, :receive_event, [payload, remote_domain]) do
        {:ok, result} when result in [:applied, :duplicate, :stale] ->
          {:ok, :recovered}

        {:error, post_reason} ->
          {:error, {:post_recovery_apply_failed, post_reason}}
      end
    else
      nil -> {:error, :unknown_peer}
      {:error, snapshot_reason} -> {:error, snapshot_reason}
      _ -> {:error, reason}
    end
  end

  defp current_stream_sequence(remote_domain, stream_id) do
    from(p in FederationStreamPosition,
      where: p.origin_domain == ^remote_domain and p.stream_id == ^stream_id,
      select: p.last_sequence
    )
    |> Repo.one()
    |> case do
      nil -> 0
      sequence -> sequence
    end
  end

  defp snapshot_recovery_domain(payload, remote_domain, context)
       when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    authority_domain = infer_room_origin_domain(payload)
    local_domain = call(context, :local_domain, [])

    cond do
      !is_binary(authority_domain) ->
        remote_domain

      String.downcase(authority_domain) == String.downcase(local_domain || "") ->
        remote_domain

      true ->
        String.downcase(authority_domain)
    end
  end

  defp snapshot_recovery_domain(_payload, remote_domain, _context), do: remote_domain

  defp snapshot_recovery_peer(snapshot_remote_domain, peer, context)
       when is_binary(snapshot_remote_domain) and is_map(context) do
    case call(context, :outgoing_peer, [snapshot_remote_domain]) ||
           call(context, :incoming_peer, [snapshot_remote_domain]) do
      %{} = resolved_peer -> resolved_peer
      _ -> peer
    end
  end

  defp snapshot_recovery_peer(_snapshot_remote_domain, peer, _context), do: peer

  defp fetch_remote_stream_events(peer, stream_id, after_sequence, limit, context)
       when is_binary(stream_id) and is_integer(after_sequence) and is_integer(limit) and
              is_map(context) do
    if call(context, :peer_supports, [peer, "session_transport", false]) &&
         is_binary(call(context, :outbound_session_websocket_url, [peer])) do
      case FederationSessionClient.send_request(
             peer,
             "stream_events",
             %{
               "stream_id" => stream_id,
               "after_sequence" => after_sequence,
               "limit" => limit
             },
             timeout: call(context, :delivery_timeout_ms, [])
           ) do
        {:ok, %{} = payload} ->
          {:ok, payload}

        {:error, _reason} ->
          fetch_remote_stream_events_over_http(peer, stream_id, after_sequence, limit, context)
      end
    else
      fetch_remote_stream_events_over_http(peer, stream_id, after_sequence, limit, context)
    end
  end

  defp fetch_remote_stream_events_over_http(peer, stream_id, after_sequence, limit, context) do
    path = "/_arblarg/streams/events"

    query_string =
      URI.encode_query([
        {"stream_id", stream_id},
        {"after_sequence", Integer.to_string(after_sequence)},
        {"limit", Integer.to_string(limit)}
      ])

    url = call(context, :outbound_stream_events_url, [peer, query_string])
    headers = call(context, :signed_headers, [peer, "GET", path, query_string, ""])
    request = Finch.build(:get, url, headers)

    case SafeFetch.request(request, Elektrine.Finch,
           receive_timeout: call(context, :delivery_timeout_ms, []),
           pool_timeout: 5000
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} -> {:ok, payload}
          _ -> {:error, :invalid_stream_replay_response}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, call(context, :truncate, [body])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_stream_replay_events(events, remote_domain, context)
       when is_list(events) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case call(context, :receive_event, [event, remote_domain]) do
        {:ok, _result} -> {:cont, :ok}
        {:error, :sequence_gap} -> {:halt, {:error, :sequence_gap}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp import_stream_replay_events(_events, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp recover_stream_replay_pages(peer, remote_domain, stream_id, after_sequence, context)
       when is_binary(remote_domain) and is_binary(stream_id) and is_integer(after_sequence) and
              is_map(context) do
    with {:ok, replay_payload} <-
           fetch_remote_stream_events(
             peer,
             stream_id,
             after_sequence,
             call(context, :stream_replay_limit, []),
             context
           ),
         events when is_list(events) <- replay_payload["events"],
         :ok <- import_stream_replay_events(events, remote_domain, context) do
      if replay_payload["has_more"] == true do
        next_after_sequence =
          call(context, :parse_int, [replay_payload["next_after_sequence"], after_sequence])

        if next_after_sequence > after_sequence do
          recover_stream_replay_pages(
            peer,
            remote_domain,
            stream_id,
            next_after_sequence,
            context
          )
        else
          {:error, :stream_recovery_failed}
        end
      else
        :ok
      end
    else
      _ -> {:error, :stream_recovery_failed}
    end
  end

  defp recover_stream_replay_pages(_peer, _remote_domain, _stream_id, _after_sequence, _context),
    do: {:error, :stream_recovery_failed}

  defp last_read_chat_message(conversation_id, %DateTime{} = last_read_at)
       when is_integer(conversation_id) do
    last_read_at = DateTime.to_naive(last_read_at)

    from(m in ChatMessage,
      where: m.conversation_id == ^conversation_id and m.inserted_at <= ^last_read_at,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp last_read_chat_message(_conversation_id, _last_read_at), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
