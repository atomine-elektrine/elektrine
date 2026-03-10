defmodule Elektrine.Messaging.Federation.Snapshots do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.{
    ChatMessage,
    CommunityBan,
    Conversation,
    ConversationMember,
    FederationInviteState,
    FederationOutboxEvent,
    FederationSessionClient,
    FederationStreamPosition,
    Server
  }
  alias Elektrine.Repo

  def build_server_snapshot(server_id, opts, context)
      when is_integer(server_id) and is_list(opts) and is_map(context) do
    messages_per_channel =
      call(context, :parse_int, [Keyword.get(opts, :messages_per_channel, 25), 25])
      |> max(1)
      |> min(250)

    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        from(c in Conversation,
          where:
            c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
          order_by: [asc: c.channel_position, asc: c.inserted_at]
        )
        |> Repo.all()
        |> Enum.take(call(context, :snapshot_channel_limit, []))

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
        "stream_positions" => snapshot_stream_positions(server, channels, context)
      }

      {:ok, sign_snapshot_payload(unsigned, context)}
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  def import_server_snapshot(payload, remote_domain, context)
      when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    with :ok <- call(context, :validate_snapshot_payload, [payload, remote_domain]) do
      Repo.transaction(fn ->
        with {:ok, mirror_server} <- call(context, :upsert_mirror_server, [payload["server"], remote_domain]),
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
    after_sequence = call(context, :parse_int, [Keyword.get(opts, :after_sequence, 0), 0]) |> max(0)
    limit =
      call(context, :parse_int, [
        Keyword.get(opts, :limit, call(context, :stream_replay_limit, [])),
        call(context, :stream_replay_limit, [])
      ])

    bounded_limit = limit |> max(1) |> min(call(context, :stream_replay_limit, []))

    events =
      from(o in FederationOutboxEvent,
        where: o.stream_id == ^stream_id and o.sequence > ^after_sequence,
        order_by: [asc: o.sequence, asc: o.id],
        limit: ^bounded_limit,
        select: %{sequence: o.sequence, payload: o.payload}
      )
      |> Repo.all()

    last_sequence =
      from(o in FederationOutboxEvent,
        where: o.stream_id == ^stream_id,
        select: max(o.sequence)
      )
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
           call(context, :outgoing_peer, [remote_domain]) || call(context, :incoming_peer, [remote_domain]),
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
    path = "/federation/messaging/sync"
    url = call(context, :outbound_sync_url, [peer])
    body = Jason.encode!(snapshot)
    headers = call(context, :signed_headers, [peer, "POST", path, "", body])
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
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

  def snapshot_governance_entries(governance, context) when is_map(governance) and is_map(context) do
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
      [call(context, :server_stream_id, [server.id]) | Enum.map(channels, &call(context, :channel_stream_id, [&1.id]))]

    stream_ids
    |> Enum.uniq()
    |> Enum.map(fn stream_id ->
      %{
        "stream_id" => stream_id,
        "last_sequence" => local_last_sequence_for_stream(stream_id)
      }
    end)
  end

  defp snapshot_stream_positions(_server, _channels, _context), do: []

  defp snapshot_governance_payload(%Server{} = server, channels, context) when is_list(channels) do
    channel_ids = Enum.map(channels, & &1.id)
    channel_index = Map.new(channels, &{&1.id, &1})

    memberships =
      from(member in ConversationMember,
        where: member.conversation_id in ^channel_ids,
        preload: [:user, :conversation],
        order_by: [asc: member.conversation_id, asc: member.user_id]
      )
      |> Repo.all()
      |> Enum.take(call(context, :snapshot_governance_limit, []))
      |> Enum.reduce([], fn member, acc ->
        with %User{} = user <- member.user,
             %Conversation{} = conversation <- member.conversation,
             %Conversation{} = indexed_channel <- Map.get(channel_index, conversation.id) do
          payload = %{
            "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
            "membership" => %{
              "actor" => call(context, :sender_payload, [user]),
              "role" => member.role || "member",
              "state" => if(is_nil(member.left_at), do: "active", else: "left"),
              "joined_at" => call(context, :format_created_at, [member.joined_at]),
              "updated_at" => call(context, :format_created_at, [member.updated_at])
            }
          }

          acc ++ [payload]
        else
          _ -> acc
        end
      end)

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
        with %Conversation{} = indexed_channel <- Map.get(channel_index, invite.conversation_id),
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
      from(ban in CommunityBan,
        where: ban.conversation_id in ^channel_ids,
        preload: [:user, :banned_by, :conversation],
        order_by: [asc: ban.conversation_id, asc: ban.user_id]
      )
      |> Repo.all()
      |> Enum.take(remaining_governance_slots)
      |> Enum.reduce([], fn ban, acc ->
        with %User{} = target_user <- ban.user,
             %User{} = actor_user <- ban.banned_by,
             %Conversation{} = conversation <- ban.conversation,
             %Conversation{} = indexed_channel <- Map.get(channel_index, conversation.id) do
          payload = %{
            "refs" => call(context, :event_refs_payload, [server, indexed_channel]),
            "ban" => %{
              "actor" => call(context, :sender_payload, [actor_user]),
              "target" => call(context, :sender_payload, [target_user]),
              "state" => "active",
              "reason" => call(context, :normalize_optional_string, [ban.reason]),
              "banned_at" => call(context, :format_created_at, [ban.inserted_at]),
              "updated_at" => call(context, :format_created_at, [ban.updated_at]),
              "expires_at" => call(context, :maybe_iso8601, [ban.expires_at]),
              "metadata" => %{}
            }
          }

          acc ++ [payload]
        else
          _ -> acc
        end
      end)

    %{"memberships" => memberships, "invites" => invites, "bans" => bans}
  end

  defp snapshot_governance_payload(_server, _channels, _context),
    do: %{"memberships" => [], "invites" => [], "bans" => []}

  defp import_snapshot_governance(_channel_map, governance, remote_domain, context)
       when is_map(governance) and is_binary(remote_domain) and is_map(context) do
    governance
    |> snapshot_governance_entries(context)
    |> Enum.reduce_while(:ok, fn {event_type, payload}, :ok ->
      case call(context, :validate_snapshot_governance_payload, [event_type, payload, remote_domain]) do
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
      stream_id =
        call(context, :normalize_optional_string, [position["stream_id"] || position[:stream_id]])

      last_sequence = call(context, :parse_int, [position["last_sequence"] || position[:last_sequence], -1])

      cond do
        !is_binary(stream_id) ->
          {:halt, {:error, :invalid_snapshot_stream_positions}}

        last_sequence < 0 ->
          {:halt, {:error, :invalid_snapshot_stream_positions}}

        last_sequence > current_stream_sequence(remote_domain, stream_id) ->
          call(context, :store_stream_position, [remote_domain, stream_id, last_sequence])
          {:cont, :ok}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp store_snapshot_stream_positions(_stream_positions, _remote_domain, _context),
    do: {:error, :invalid_snapshot_stream_positions}

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
    path = "/federation/messaging/servers/#{remote_server_id}/snapshot"
    url = call(context, :outbound_snapshot_url, [peer, remote_server_id])
    headers = call(context, :signed_headers, [peer, "GET", path, "", ""])
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Elektrine.Finch,
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
      :ok
    else
      _ -> {:error, :stream_recovery_failed}
    end
  end

  defp recover_sequence_gap_via_snapshot(payload, remote_domain, peer, reason, context)
       when is_binary(remote_domain) and is_map(context) do
    with {:ok, remote_server_id} <- call(context, :infer_remote_server_id, [payload]),
         {:ok, snapshot_payload} <- fetch_remote_snapshot(peer, remote_server_id, context),
         {:ok, _mirror_server} <- import_server_snapshot(snapshot_payload, remote_domain, context) do
      case call(context, :receive_event, [payload, remote_domain]) do
        {:ok, result} when result in [:applied, :duplicate, :stale] ->
          {:ok, :recovered}

        {:error, post_reason} ->
          {:error, {:post_recovery_apply_failed, post_reason}}
      end
    else
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
    path = "/federation/messaging/streams/events"

    query_string =
      URI.encode_query([
        {"stream_id", stream_id},
        {"after_sequence", Integer.to_string(after_sequence)},
        {"limit", Integer.to_string(limit)}
      ])

    url = call(context, :outbound_stream_events_url, [peer, query_string])
    headers = call(context, :signed_headers, [peer, "GET", path, query_string, ""])
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Elektrine.Finch,
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

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
