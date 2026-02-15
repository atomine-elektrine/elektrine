defmodule Elektrine.Messaging.Federation do
  @moduledoc """
  Lightweight federation support for Discord-style messaging servers.

  This module now supports both:
  - snapshot sync (coarse-grained)
  - real-time event sync with per-stream sequencing and idempotency
  """

  import Ecto.Query, warn: false
  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.Async

  alias Elektrine.Messaging.{
    ChatMessage,
    Conversation,
    FederationEvent,
    FederationOutboxEvent,
    FederationOutboxWorker,
    FederationStreamPosition,
    Server
  }

  alias Elektrine.Repo

  @clock_skew_seconds 300

  @doc """
  Returns true when messaging federation is enabled.
  """
  def enabled? do
    federation_config()
    |> Keyword.get(:enabled, false)
  end

  @doc """
  Returns normalized peer configs.
  """
  def peers do
    federation_config()
    |> Keyword.get(:peers, [])
    |> Enum.map(&normalize_peer/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns the peer config for incoming requests by domain.
  """
  def incoming_peer(domain) when is_binary(domain) do
    normalized = String.downcase(domain)

    Enum.find(peers(), fn peer ->
      peer.allow_incoming and String.downcase(peer.domain) == normalized
    end)
  end

  @doc """
  Returns outgoing-enabled peers.
  """
  def outgoing_peers do
    Enum.filter(peers(), & &1.allow_outgoing)
  end

  @doc """
  Public discovery document for cross-domain federation bootstrap.
  """
  def local_discovery_document do
    base_url = ActivityPub.instance_url()

    %{
      "version" => 1,
      "domain" => ActivityPub.instance_domain(),
      "identity" => %{
        "algorithm" => "hmac-sha256",
        "current_key_id" => local_identity_key_id()
      },
      "features" => %{
        "event_federation" => true,
        "snapshot_sync" => true,
        "ordered_streams" => true,
        "idempotent_events" => true
      },
      "endpoints" => %{
        "events" => "#{base_url}/federation/messaging/events",
        "sync" => "#{base_url}/federation/messaging/sync",
        "snapshot_template" => "#{base_url}/federation/messaging/servers/{server_id}/snapshot"
      }
    }
  end

  @doc """
  Builds the canonical string that gets signed for federation requests.
  """
  def signature_payload(domain, method, _request_path, _query_string, timestamp) do
    [
      String.downcase(to_string(domain || "")),
      String.downcase(to_string(method || "")),
      to_string(timestamp || "")
    ]
    |> Enum.join("\n")
  end

  @doc """
  Signs a payload with HMAC SHA-256.
  """
  def sign_payload(payload, secret) when is_binary(secret) and is_binary(payload) do
    hmac_raw(secret, payload)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Validates timestamp freshness.
  """
  def valid_timestamp?(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {ts, ""} ->
        abs(System.system_time(:second) - ts) <= @clock_skew_seconds

      _ ->
        false
    end
  end

  @doc """
  Verifies an incoming signature for the request using a raw secret.
  """
  def verify_signature(secret, domain, method, request_path, query_string, timestamp, signature)
      when is_binary(secret) and is_binary(signature) do
    payload = signature_payload(domain, method, request_path, query_string, timestamp)
    expected_raw = hmac_raw(secret, payload)

    case Base.url_decode64(String.trim(signature), padding: false) do
      {:ok, provided_raw} ->
        byte_size(provided_raw) == byte_size(expected_raw) and
          Plug.Crypto.secure_compare(provided_raw, expected_raw)

      :error ->
        false
    end
  end

  @doc """
  Verifies an incoming signature using a normalized peer config and optional key id.
  Supports key rotation by accepting any configured incoming key for the peer.
  """
  def verify_signature(
        peer,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        key_id,
        signature
      )
      when is_map(peer) and is_binary(signature) do
    peer
    |> incoming_secrets_for_key_id(key_id)
    |> Enum.any?(fn secret ->
      verify_signature(secret, domain, method, request_path, query_string, timestamp, signature)
    end)
  end

  @doc """
  Builds headers for an outgoing signed federation request.
  """
  def signed_headers(peer, method, request_path, query_string \\ "") do
    timestamp = Integer.to_string(System.system_time(:second))
    domain = ActivityPub.instance_domain()
    {key_id, secret} = outbound_signing_material(peer)

    signature =
      signature_payload(domain, method, request_path, query_string, timestamp)
      |> sign_payload(secret)

    [
      {"content-type", "application/json"},
      {"x-elektrine-federation-domain", domain},
      {"x-elektrine-federation-key-id", key_id},
      {"x-elektrine-federation-timestamp", timestamp},
      {"x-elektrine-federation-signature", signature}
    ]
  end

  @doc """
  Builds a federated snapshot for a local server.
  """
  def build_server_snapshot(server_id, opts \\ []) do
    messages_per_channel = Keyword.get(opts, :messages_per_channel, 25)

    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        from(c in Conversation,
          where:
            c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
          order_by: [asc: c.channel_position, asc: c.inserted_at]
        )
        |> Repo.all()

      channel_payloads = Enum.map(channels, &channel_payload/1)

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
          |> Enum.map(fn message ->
            message_payload(message, channel)
          end)
        end)

      {:ok,
       %{
         "version" => 1,
         "origin_domain" => ActivityPub.instance_domain(),
         "server" => server_payload(server),
         "channels" => channel_payloads,
         "messages" => channel_messages
       }}
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  @doc """
  Imports a federated server snapshot from a trusted remote domain.
  """
  def import_server_snapshot(payload, remote_domain) when is_binary(remote_domain) do
    with :ok <- validate_snapshot_payload(payload, remote_domain) do
      Repo.transaction(fn ->
        {:ok, mirror_server} = upsert_mirror_server(payload["server"], remote_domain)
        channel_map = upsert_mirror_channels(mirror_server, payload["channels"] || [])
        upsert_mirror_messages(channel_map, payload["messages"] || [], remote_domain)
        {:ok, mirror_server}
      end)
      |> case do
        {:ok, {:ok, server}} -> {:ok, server}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Processes a single incoming real-time federation event.

  Guarantees:
  - idempotency by global event_id
  - in-order application per origin_domain + stream_id
  """
  def receive_event(payload, remote_domain) when is_binary(remote_domain) do
    with :ok <- validate_event_payload(payload, remote_domain) do
      Repo.transaction(fn ->
        case claim_event_id(payload, remote_domain) do
          :duplicate ->
            :duplicate

          :new ->
            case check_sequence(payload, remote_domain) do
              :stale ->
                :stale

              :ok ->
                with :ok <-
                       apply_event(payload["event_type"], payload["data"] || %{}, remote_domain),
                     :ok <-
                       store_stream_position(
                         remote_domain,
                         payload["stream_id"],
                         payload["sequence"]
                       ) do
                  :applied
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, result} when result in [:applied, :duplicate, :stale] -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Attempts automatic gap recovery by fetching a trusted remote snapshot.
  """
  def recover_sequence_gap(payload, remote_domain) when is_binary(remote_domain) do
    with %{} = peer <- incoming_peer(remote_domain),
         {:ok, remote_server_id} <- infer_remote_server_id(payload),
         {:ok, snapshot_payload} <- fetch_remote_snapshot(peer, remote_server_id),
         {:ok, _mirror_server} <- import_server_snapshot(snapshot_payload, remote_domain),
         :ok <- store_stream_position(remote_domain, payload["stream_id"], payload["sequence"]) do
      {:ok, :recovered}
    else
      nil ->
        {:error, :unknown_peer}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :recovery_failed}
    end
  end

  @doc """
  Pushes a local server snapshot to all configured outgoing peers.
  """
  def push_server_snapshot(server_id) do
    if enabled?() do
      with {:ok, snapshot} <- build_server_snapshot(server_id) do
        Enum.each(outgoing_peers(), fn peer ->
          push_snapshot_to_peer(peer, snapshot)
        end)
      end
    end

    :ok
  end

  @doc """
  Publishes a real-time server upsert event.
  """
  def publish_server_upsert(server_id) do
    if enabled?() do
      with {:ok, event} <- build_server_upsert_event(server_id) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  @doc """
  Publishes a real-time message.create event.
  """
  def publish_message_created(%ChatMessage{} = message) do
    if enabled?() do
      with {:ok, event} <- build_message_created_event(message) do
        enqueue_outbox_event(event)
      end
    end

    :ok
  end

  def publish_message_created(message_id) when is_integer(message_id) do
    case Repo.get(ChatMessage, message_id) do
      nil -> :ok
      message -> publish_message_created(message)
    end
  end

  @doc """
  Backward-compatible trigger used by existing call sites.
  """
  def maybe_push_for_conversation(conversation_id) do
    if enabled?() do
      Async.start(fn -> publish_latest_message_event(conversation_id) end)
    end

    :ok
  end

  @doc """
  Backward-compatible trigger used by existing call sites.
  """
  def maybe_push_for_server(server_id) do
    if enabled?() do
      Async.start(fn -> publish_server_upsert(server_id) end)
    end

    :ok
  end

  @doc """
  Processes one outbox row and attempts delivery to pending peers with bounded concurrency.
  """
  def process_outbox_event(outbox_event_id) when is_integer(outbox_event_id) do
    Repo.transaction(fn ->
      outbox =
        from(o in FederationOutboxEvent, where: o.id == ^outbox_event_id, lock: "FOR UPDATE")
        |> Repo.one()

      case outbox do
        nil ->
          :not_found

        %{status: "delivered"} ->
          :already_delivered

        %{status: "failed"} ->
          :already_failed

        %{next_retry_at: %DateTime{} = next_retry_at} ->
          if DateTime.compare(next_retry_at, DateTime.utc_now()) == :gt do
            :not_due
          else
            do_process_outbox(outbox)
          end

        _ ->
          do_process_outbox(outbox)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Enqueues due pending outbox events for processing.
  """
  def enqueue_due_outbox_events(limit \\ 500) do
    now = DateTime.utc_now()

    outbox_event_ids =
      from(o in FederationOutboxEvent,
        where:
          o.status == "pending" and o.attempt_count < o.max_attempts and
            o.next_retry_at <= ^now,
        order_by: [asc: o.next_retry_at, asc: o.id],
        limit: ^limit,
        select: o.id
      )
      |> Repo.all()

    _ = FederationOutboxWorker.enqueue_many(outbox_event_ids)
    length(outbox_event_ids)
  end

  @doc """
  Runs retention for federation event and outbox tables.
  """
  def run_retention do
    archive_old_events()
    prune_old_outbox_rows()
    :ok
  end

  defp validate_snapshot_payload(payload, remote_domain) when is_map(payload) do
    origin_domain = payload["origin_domain"]
    server = payload["server"] || %{}

    cond do
      payload["version"] != 1 ->
        {:error, :unsupported_version}

      origin_domain != remote_domain ->
        {:error, :origin_domain_mismatch}

      !is_map(server) ->
        {:error, :invalid_server_payload}

      !is_binary(server["id"]) or !is_binary(server["name"]) ->
        {:error, :invalid_server_payload}

      true ->
        :ok
    end
  end

  defp validate_snapshot_payload(_payload, _remote_domain), do: {:error, :invalid_payload}

  defp validate_event_payload(payload, remote_domain) when is_map(payload) do
    cond do
      payload["version"] != 1 ->
        {:error, :unsupported_version}

      payload["origin_domain"] != remote_domain ->
        {:error, :origin_domain_mismatch}

      !is_binary(payload["event_id"]) ->
        {:error, :invalid_event_id}

      !is_binary(payload["event_type"]) ->
        {:error, :invalid_event_type}

      !is_binary(payload["stream_id"]) ->
        {:error, :invalid_stream_id}

      parse_int(payload["sequence"], 0) <= 0 ->
        {:error, :invalid_sequence}

      !is_map(payload["data"] || %{}) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_event_payload(_, _), do: {:error, :invalid_payload}

  defp claim_event_id(payload, remote_domain) do
    inserted_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    received_now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = [
      %{
        event_id: payload["event_id"],
        origin_domain: remote_domain,
        event_type: payload["event_type"],
        stream_id: payload["stream_id"],
        sequence: parse_int(payload["sequence"], 0),
        payload: payload,
        received_at: received_now,
        inserted_at: inserted_now
      }
    ]

    {count, _} =
      Repo.insert_all(FederationEvent, attrs,
        on_conflict: :nothing,
        conflict_target: [:event_id]
      )

    if count == 1, do: :new, else: :duplicate
  end

  defp check_sequence(payload, remote_domain) do
    stream_id = payload["stream_id"]
    incoming_sequence = parse_int(payload["sequence"], 0)

    position =
      from(p in FederationStreamPosition,
        where: p.origin_domain == ^remote_domain and p.stream_id == ^stream_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    last_sequence = if position, do: position.last_sequence, else: 0

    cond do
      incoming_sequence <= last_sequence ->
        :stale

      incoming_sequence > last_sequence + 1 ->
        {:error, :sequence_gap}

      true ->
        :ok
    end
  end

  defp store_stream_position(remote_domain, stream_id, sequence) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = [
      %{
        origin_domain: remote_domain,
        stream_id: stream_id,
        last_sequence: parse_int(sequence, 0),
        inserted_at: now,
        updated_at: now
      }
    ]

    {_count, _} =
      Repo.insert_all(FederationStreamPosition, attrs,
        on_conflict: [set: [last_sequence: parse_int(sequence, 0), updated_at: now]],
        conflict_target: [:origin_domain, :stream_id]
      )

    :ok
  end

  defp apply_event("server.upsert", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain) do
      upsert_mirror_channels(mirror_server, data["channels"] || [])
      :ok
    else
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event("message.create", data, remote_domain) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = message_payload <- data["message"],
         {:ok, mirror_server} <- upsert_mirror_server(server_payload, remote_domain),
         {:ok, mirror_channel} <- upsert_single_mirror_channel(mirror_server, channel_payload),
         {:ok, _message_or_duplicate} <-
           upsert_mirror_message(mirror_channel, message_payload, remote_domain) do
      :ok
    else
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_event(_, _, _), do: {:error, :unsupported_event_type}

  defp build_server_upsert_event(server_id) do
    with %Server{} = server <- Repo.get(Server, server_id),
         false <- server.is_federated_mirror do
      channels =
        from(c in Conversation,
          where:
            c.server_id == ^server.id and c.type == "channel" and c.is_federated_mirror != true,
          order_by: [asc: c.channel_position, asc: c.inserted_at]
        )
        |> Repo.all()

      stream_id = server_stream_id(server.id)
      sequence = next_outbound_sequence(stream_id)

      {:ok,
       event_envelope("server.upsert", stream_id, sequence, %{
         "server" => server_payload(server),
         "channels" => Enum.map(channels, &channel_payload/1)
       })}
    else
      nil -> {:error, :not_found}
      true -> {:error, :federated_mirror}
    end
  end

  defp build_message_created_event(%ChatMessage{} = message) do
    message = Repo.preload(message, [:sender, conversation: [:server]])
    conversation = message.conversation
    server = if conversation, do: conversation.server, else: nil

    cond do
      is_nil(conversation) or is_nil(server) ->
        {:error, :not_found}

      conversation.type != "channel" ->
        {:error, :unsupported_conversation_type}

      server.is_federated_mirror ->
        {:error, :federated_mirror}

      true ->
        stream_id = channel_stream_id(conversation.id)
        sequence = next_outbound_sequence(stream_id)

        {:ok,
         event_envelope("message.create", stream_id, sequence, %{
           "server" => server_payload(server),
           "channel" => channel_payload(conversation),
           "message" => message_payload(message, conversation)
         })}
    end
  end

  defp event_envelope(event_type, stream_id, sequence, data) do
    %{
      "version" => 1,
      "event_id" => Ecto.UUID.generate(),
      "event_type" => event_type,
      "origin_domain" => ActivityPub.instance_domain(),
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "data" => data
    }
  end

  defp enqueue_outbox_event(event) do
    peer_domains =
      outgoing_peers()
      |> Enum.map(& &1.domain)
      |> Enum.uniq()

    if peer_domains == [] do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        event_id: event["event_id"],
        event_type: event["event_type"],
        stream_id: event["stream_id"],
        sequence: parse_int(event["sequence"], 0),
        payload: event,
        target_domains: peer_domains,
        delivered_domains: [],
        attempt_count: 0,
        max_attempts: outbox_max_attempts(),
        status: "pending",
        next_retry_at: now,
        partition_month: outbox_partition_month(now)
      }

      case %FederationOutboxEvent{}
           |> FederationOutboxEvent.changeset(attrs)
           |> Repo.insert() do
        {:ok, outbox_event} ->
          _ = FederationOutboxWorker.enqueue(outbox_event.id)
          :ok

        {:error, %Ecto.Changeset{errors: [event_id: _]}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to enqueue federation outbox event: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp do_process_outbox(outbox) do
    pending = pending_domains(outbox)

    if pending == [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      outbox
      |> FederationOutboxEvent.changeset(%{
        status: "delivered",
        dispatched_at: now,
        delivered_domains: outbox.target_domains
      })
      |> Repo.update()

      :delivered
    else
      {successful_domains, failed_domains} = deliver_outbox_domains(outbox.payload, pending)
      delivered_domains = Enum.uniq(outbox.delivered_domains ++ successful_domains)

      if failed_domains == [] do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        outbox
        |> FederationOutboxEvent.changeset(%{
          status: "delivered",
          delivered_domains: delivered_domains,
          dispatched_at: now,
          attempt_count: outbox.attempt_count + 1,
          next_retry_at: now,
          last_error: nil
        })
        |> Repo.update()

        :delivered
      else
        attempt_count = outbox.attempt_count + 1
        exhausted = attempt_count >= outbox.max_attempts
        backoff_seconds = outbox_backoff_seconds(attempt_count)
        next_retry_at = DateTime.add(DateTime.utc_now(), backoff_seconds, :second)
        status = if exhausted, do: "failed", else: "pending"

        error_reason =
          failed_domains
          |> Enum.map(fn {domain, reason} -> "#{domain}: #{inspect(reason)}" end)
          |> Enum.join("; ")

        outbox
        |> FederationOutboxEvent.changeset(%{
          status: status,
          delivered_domains: delivered_domains,
          attempt_count: attempt_count,
          next_retry_at: next_retry_at,
          last_error: error_reason
        })
        |> Repo.update()

        if exhausted, do: :failed, else: :pending_retry
      end
    end
  end

  defp pending_domains(outbox) do
    delivered = MapSet.new(outbox.delivered_domains || [])

    outbox.target_domains
    |> Enum.reject(&MapSet.member?(delivered, &1))
  end

  defp deliver_outbox_domains(event_payload, domains) do
    peer_map =
      outgoing_peers()
      |> Enum.map(fn peer -> {String.downcase(peer.domain), peer} end)
      |> Map.new()

    domains
    |> Task.async_stream(
      fn domain ->
        normalized = String.downcase(domain)

        case Map.get(peer_map, normalized) do
          nil ->
            {:error, domain, :unknown_peer}

          peer ->
            case push_event_to_peer(peer, event_payload) do
              :ok -> {:ok, domain}
              {:error, reason} -> {:error, domain, reason}
            end
        end
      end,
      max_concurrency: delivery_concurrency(),
      timeout: delivery_timeout_ms(),
      ordered: false
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, domain}}, {successes, failures} ->
        {[domain | successes], failures}

      {:ok, {:error, domain, reason}}, {successes, failures} ->
        {successes, [{domain, reason} | failures]}

      {:exit, reason}, {successes, failures} ->
        {successes, [{"unknown", {:task_exit, reason}} | failures]}
    end)
  end

  defp push_event_to_peer(peer, event) do
    path = "/federation/messaging/events"
    url = "#{peer.base_url}#{path}"
    body = Jason.encode!(event)
    headers = signed_headers(peer, "POST", path, "")

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: delivery_timeout_ms(),
           pool_timeout: 5_000
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, truncate(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_snapshot_to_peer(peer, snapshot) do
    path = "/federation/messaging/sync"
    url = "#{peer.base_url}#{path}"
    body = Jason.encode!(snapshot)
    headers = signed_headers(peer, "POST", path, "")

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: delivery_timeout_ms(),
           pool_timeout: 5_000
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning(
          "Messaging federation sync failed for #{peer.domain}: HTTP #{status} #{truncate(response_body)}"
        )

      {:error, reason} ->
        Logger.warning(
          "Messaging federation sync transport error for #{peer.domain}: #{inspect(reason)}"
        )
    end
  end

  defp fetch_remote_snapshot(peer, remote_server_id) when is_integer(remote_server_id) do
    path = "/federation/messaging/servers/#{remote_server_id}/snapshot"
    url = "#{peer.base_url}#{path}"
    headers = signed_headers(peer, "GET", path, "")
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: delivery_timeout_ms(),
           pool_timeout: 5_000
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} -> {:ok, payload}
          _ -> {:error, :invalid_snapshot_response}
        end

      {:ok, %Finch.Response{status: status}} when status in [404, 422] ->
        {:error, :snapshot_unavailable}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_mirror_server(server_payload, remote_domain) do
    attrs = %{
      name: server_payload["name"],
      description: server_payload["description"],
      icon_url: server_payload["icon_url"],
      is_public: server_payload["is_public"] == true,
      member_count: parse_int(server_payload["member_count"], 0),
      federation_id: server_payload["id"],
      origin_domain: remote_domain,
      is_federated_mirror: true,
      last_federated_at: DateTime.utc_now()
    }

    case Repo.get_by(Server, federation_id: server_payload["id"]) do
      nil ->
        %Server{}
        |> Server.changeset(attrs)
        |> Repo.insert()

      server ->
        server
        |> Server.changeset(attrs)
        |> Repo.update()
    end
  end

  defp upsert_mirror_channels(server, channels) when is_list(channels) do
    Enum.reduce(channels, %{}, fn payload, acc ->
      case upsert_single_mirror_channel(server, payload) do
        {:ok, channel} -> Map.put(acc, payload["id"], channel)
        _ -> acc
      end
    end)
  end

  defp upsert_single_mirror_channel(server, %{"id" => channel_id} = channel_payload) do
    attrs = %{
      name: channel_payload["name"] || "channel",
      description: channel_payload["description"],
      channel_topic: channel_payload["topic"],
      channel_position: parse_int(channel_payload["position"], 0),
      creator_id: nil,
      server_id: server.id,
      is_public: true,
      is_federated_mirror: true,
      federated_source: channel_id
    }

    case Repo.get_by(Conversation, type: "channel", federated_source: channel_id) do
      nil ->
        %Conversation{}
        |> Conversation.channel_changeset(attrs)
        |> Repo.insert()

      channel ->
        channel
        |> Conversation.changeset(attrs)
        |> Repo.update()
    end
  end

  defp upsert_single_mirror_channel(_server, _), do: {:error, :invalid_channel}

  defp upsert_mirror_messages(channel_map, messages, remote_domain) when is_list(messages) do
    Enum.each(messages, fn payload ->
      channel = Map.get(channel_map, payload["channel_id"])

      if channel do
        _ = upsert_mirror_message(channel, payload, remote_domain)
      end
    end)
  end

  defp upsert_mirror_message(channel, payload, remote_domain) do
    federation_id = payload["id"]

    cond do
      is_nil(channel) ->
        {:error, :invalid_channel}

      !is_binary(federation_id) ->
        {:error, :invalid_message_payload}

      Repo.get_by(ChatMessage, conversation_id: channel.id, federated_source: federation_id) ->
        {:ok, :duplicate}

      true ->
        media_metadata =
          (payload["media_metadata"] || %{})
          |> Map.put("remote_sender", payload["sender"] || %{})

        attrs = %{
          conversation_id: channel.id,
          sender_id: nil,
          content: payload["content"],
          message_type: normalize_message_type(payload["message_type"]),
          media_urls: payload["media_urls"] || [],
          media_metadata: media_metadata,
          federated_source: federation_id,
          origin_domain: remote_domain,
          is_federated_mirror: true
        }

        %ChatMessage{}
        |> ChatMessage.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp publish_latest_message_event(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{type: "channel", server_id: server_id} when not is_nil(server_id) ->
        case Repo.get(Server, server_id) do
          %Server{is_federated_mirror: false} ->
            from(m in ChatMessage,
              where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
              order_by: [desc: m.inserted_at],
              limit: 1
            )
            |> Repo.one()
            |> case do
              nil -> :ok
              latest -> publish_message_created(latest)
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp next_outbound_sequence(stream_id) do
    sql = """
    INSERT INTO messaging_federation_stream_counters (stream_id, next_sequence, inserted_at, updated_at)
    VALUES ($1, 2, NOW(), NOW())
    ON CONFLICT (stream_id)
    DO UPDATE
      SET next_sequence = messaging_federation_stream_counters.next_sequence + 1,
          updated_at = NOW()
    RETURNING next_sequence - 1
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [stream_id]) do
      {:ok, %{rows: [[sequence]]}} when is_integer(sequence) -> sequence
      _ -> 1
    end
  end

  defp server_stream_id(server_id), do: "server:" <> server_federation_id(server_id)
  defp channel_stream_id(channel_id), do: "channel:" <> channel_federation_id(channel_id)

  defp server_payload(server) do
    %{
      "id" => server.federation_id || server_federation_id(server.id),
      "name" => server.name,
      "description" => server.description,
      "icon_url" => server.icon_url,
      "is_public" => server.is_public,
      "member_count" => server.member_count
    }
  end

  defp channel_payload(channel) do
    %{
      "id" => channel.federated_source || channel_federation_id(channel.id),
      "name" => channel.name,
      "description" => channel.description,
      "topic" => channel.channel_topic,
      "position" => channel.channel_position
    }
  end

  defp message_payload(message, channel) do
    %{
      "id" => message.federated_source || message_federation_id(message.id),
      "channel_id" => channel.federated_source || channel_federation_id(channel.id),
      "content" => message.content,
      "message_type" => message.message_type,
      "media_urls" => message.media_urls || [],
      "media_metadata" => message.media_metadata || %{},
      "created_at" => format_created_at(message.inserted_at),
      "sender" => format_sender(message.sender)
    }
  end

  defp outbound_signing_material(peer) do
    active_key_id = peer.active_outbound_key_id

    case Enum.find(peer.keys, fn key -> key.id == active_key_id end) do
      %{id: id, secret: secret} -> {id, secret}
      _ -> {"legacy", peer.shared_secret}
    end
  end

  defp incoming_secrets_for_key_id(peer, key_id) do
    case normalize_optional_string(key_id) do
      nil ->
        peer.keys
        |> Enum.map(& &1.secret)
        |> Enum.reject(&is_nil/1)

      requested_key_id ->
        peer.keys
        |> Enum.filter(&(&1.id == requested_key_id))
        |> Enum.map(& &1.secret)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp truncate(nil), do: ""

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > 180 do
      binary_part(body, 0, 180) <> "..."
    else
      body
    end
  end

  defp truncate(body), do: inspect(body)

  defp normalize_message_type(type) when type in ["text", "image", "file", "voice", "system"],
    do: type

  defp normalize_message_type(_), do: "text"

  defp hmac_raw(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
  end

  defp server_federation_id(server_id) do
    "#{ActivityPub.instance_url()}/federation/messaging/servers/#{server_id}"
  end

  defp channel_federation_id(channel_id) do
    "#{ActivityPub.instance_url()}/federation/messaging/channels/#{channel_id}"
  end

  defp message_federation_id(message_id) do
    "#{ActivityPub.instance_url()}/federation/messaging/messages/#{message_id}"
  end

  defp format_sender(nil), do: nil

  defp format_sender(sender) do
    %{
      "username" => sender.username,
      "display_name" => sender.display_name || sender.username,
      "domain" => ActivityPub.instance_domain(),
      "handle" => "#{sender.username}@#{ActivityPub.instance_domain()}"
    }
  end

  defp format_created_at(nil), do: nil
  defp format_created_at(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_created_at(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp infer_remote_server_id(payload) when is_map(payload) do
    server_id_from_data =
      get_in(payload, ["data", "server", "id"])
      |> extract_trailing_integer()

    stream_id = payload["stream_id"]

    server_id_from_stream =
      case stream_id do
        "server:" <> server_federation_id ->
          extract_trailing_integer(server_federation_id)

        _ ->
          nil
      end

    case server_id_from_data || server_id_from_stream do
      nil -> {:error, :cannot_infer_snapshot_server_id}
      id -> {:ok, id}
    end
  end

  defp infer_remote_server_id(_), do: {:error, :cannot_infer_snapshot_server_id}

  defp extract_trailing_integer(nil), do: nil

  defp extract_trailing_integer(value) when is_binary(value) do
    value
    |> String.trim_trailing("/")
    |> String.split("/")
    |> List.last()
    |> case do
      nil ->
        nil

      candidate ->
        case Integer.parse(candidate) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp extract_trailing_integer(_), do: nil

  defp delivery_concurrency do
    federation_config()
    |> Keyword.get(:delivery_concurrency, 6)
  end

  defp delivery_timeout_ms do
    federation_config()
    |> Keyword.get(:delivery_timeout_ms, 12_000)
  end

  defp outbox_max_attempts do
    federation_config()
    |> Keyword.get(:outbox_max_attempts, 8)
  end

  defp outbox_base_backoff_seconds do
    federation_config()
    |> Keyword.get(:outbox_base_backoff_seconds, 5)
  end

  defp outbox_backoff_seconds(attempt_count) do
    # Exponential backoff capped at 15 minutes.
    base = outbox_base_backoff_seconds()
    trunc(min(base * :math.pow(2, max(attempt_count - 1, 0)), 900))
  end

  defp outbox_partition_month(%DateTime{} = datetime) do
    Date.new!(datetime.year, datetime.month, 1)
  end

  defp archive_old_events do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-event_retention_days() * 86_400, :second)
      |> DateTime.truncate(:second)

    sql = """
    INSERT INTO messaging_federation_events_archive (
      event_id,
      origin_domain,
      event_type,
      stream_id,
      sequence,
      payload,
      received_at,
      partition_month,
      inserted_at
    )
    SELECT
      event_id,
      origin_domain,
      event_type,
      stream_id,
      sequence,
      payload,
      received_at,
      date_trunc('month', inserted_at)::date,
      inserted_at
    FROM messaging_federation_events
    WHERE inserted_at < $1
    ON CONFLICT (event_id) DO NOTHING
    """

    _ = Ecto.Adapters.SQL.query(Repo, sql, [cutoff])

    {_deleted, _} =
      Repo.delete_all(
        from(e in FederationEvent,
          where: e.inserted_at < ^cutoff
        )
      )

    :ok
  end

  defp prune_old_outbox_rows do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-outbox_retention_days() * 86_400, :second)
      |> DateTime.truncate(:second)

    {_deleted, _} =
      Repo.delete_all(
        from(o in FederationOutboxEvent,
          where: o.updated_at < ^cutoff and o.status in ["delivered", "failed"]
        )
      )

    :ok
  end

  defp event_retention_days do
    federation_config()
    |> Keyword.get(:event_retention_days, 14)
  end

  defp outbox_retention_days do
    federation_config()
    |> Keyword.get(:outbox_retention_days, 30)
  end

  defp federation_config do
    Application.get_env(:elektrine, :messaging_federation, [])
  end

  defp local_identity_key_id do
    federation_config()
    |> Keyword.get(:identity_key_id, "default")
    |> to_string()
  end

  defp normalize_peer(peer) when is_map(peer) do
    domain = value_from(peer, :domain)
    base_url = value_from(peer, :base_url)
    shared_secret = value_from(peer, :shared_secret)
    keys = normalize_peer_keys(value_from(peer, :keys, []), shared_secret)

    cond do
      !is_binary(domain) or !is_binary(base_url) or Enum.empty?(keys) ->
        nil

      true ->
        %{
          domain: domain,
          base_url: String.trim_trailing(base_url, "/"),
          shared_secret: shared_secret,
          keys: keys,
          active_outbound_key_id: resolve_active_outbound_key_id(peer, keys),
          allow_incoming: value_from(peer, :allow_incoming, true) == true,
          allow_outgoing: value_from(peer, :allow_outgoing, true) == true
        }
    end
  end

  defp normalize_peer(peer) when is_list(peer), do: normalize_peer(Map.new(peer))
  defp normalize_peer(_), do: nil

  defp normalize_peer_keys(keys, shared_secret) when is_list(keys) do
    normalized =
      keys
      |> Enum.map(&normalize_single_peer_key/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(normalized) and is_binary(shared_secret) do
      [%{id: "legacy", secret: shared_secret, active_outbound: true}]
    else
      normalized
    end
  end

  defp normalize_peer_keys(_, shared_secret) when is_binary(shared_secret) do
    [%{id: "legacy", secret: shared_secret, active_outbound: true}]
  end

  defp normalize_peer_keys(_, _), do: []

  defp normalize_single_peer_key(key) when is_list(key),
    do: normalize_single_peer_key(Map.new(key))

  defp normalize_single_peer_key(key) when is_map(key) do
    id = value_from(key, :id)
    secret = value_from(key, :secret)

    if is_binary(id) and is_binary(secret) do
      %{
        id: id,
        secret: secret,
        active_outbound: value_from(key, :active_outbound, false) == true
      }
    else
      nil
    end
  end

  defp normalize_single_peer_key(_), do: nil

  defp resolve_active_outbound_key_id(peer, keys) do
    configured = normalize_optional_string(value_from(peer, :active_outbound_key_id))

    cond do
      is_binary(configured) and Enum.any?(keys, &(&1.id == configured)) ->
        configured

      key = Enum.find(keys, & &1.active_outbound) ->
        key.id

      true ->
        keys
        |> List.first()
        |> Map.get(:id)
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp value_from(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
