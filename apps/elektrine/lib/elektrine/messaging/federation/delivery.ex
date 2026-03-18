defmodule Elektrine.Messaging.Federation.Delivery do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.ArblargSDK

  alias Elektrine.Messaging.{
    FederationOutboxEvent,
    FederationOutboxWorker,
    FederationSessionClient
  }

  alias Elektrine.Messaging.Federation.Transport
  alias Elektrine.Repo

  @cbor_batch_content_type "application/arblarg-batch+cbor"
  @ephemeral_item_content_type "application/arblarg-ephemeral+cbor"

  def process_outbox_event(outbox_event_id, context)
      when is_integer(outbox_event_id) and is_map(context) do
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
            do_process_outbox(outbox, context)
          end

        _ ->
          do_process_outbox(outbox, context)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue_due_outbox_events(limit, _context) when is_integer(limit) do
    now = DateTime.utc_now()

    outbox_event_ids =
      from(o in FederationOutboxEvent,
        where:
          o.status == "pending" and o.attempt_count < o.max_attempts and o.next_retry_at <= ^now,
        order_by: [asc: o.next_retry_at, asc: o.id],
        limit: ^limit,
        select: o.id
      )
      |> Repo.all()

    _ = FederationOutboxWorker.enqueue_many(outbox_event_ids)
    length(outbox_event_ids)
  end

  def push_event_batch_to_peer(peer, events, context) when is_list(events) and is_map(context) do
    peer
    |> event_transport_order(context)
    |> Enum.reduce_while({:error, :no_compatible_transport}, fn transport, _acc ->
      case push_event_batch_via_transport(peer, events, transport, context) do
        {:skip, _reason} ->
          {:cont, {:error, :no_compatible_transport}}

        {:error, reason} = error ->
          if Transport.transport_fallback_reason?(reason) do
            {:cont, error}
          else
            {:halt, error}
          end

        result ->
          {:halt, result}
      end
    end)
  end

  def push_ephemeral_batch_to_peer(peer, items, context)
      when is_list(items) and is_map(context) do
    peer
    |> ephemeral_transport_order(context)
    |> Enum.reduce_while({:error, :no_compatible_transport}, fn transport, _acc ->
      case push_ephemeral_batch_via_transport(peer, items, transport, context) do
        {:skip, _reason} ->
          {:cont, {:error, :no_compatible_transport}}

        {:error, reason} = error ->
          if Transport.transport_fallback_reason?(reason) do
            {:cont, error}
          else
            {:halt, error}
          end

        result ->
          {:halt, result}
      end
    end)
  end

  defp do_process_outbox(outbox, context) do
    pending = pending_domains(outbox)

    if pending == [] do
      mark_outbox_fully_delivered(outbox)
    else
      Enum.each(pending, fn domain ->
        _ = deliver_outbox_domain_batch(outbox, domain, context)
      end)

      case Repo.get(FederationOutboxEvent, outbox.id) do
        %FederationOutboxEvent{status: "delivered"} -> :delivered
        %FederationOutboxEvent{status: "failed"} -> :failed
        %FederationOutboxEvent{} -> :pending_retry
        nil -> :not_found
      end
    end
  end

  defp pending_domains(outbox) do
    delivered = MapSet.new(outbox.delivered_domains || [])
    outbox.target_domains |> Enum.reject(&MapSet.member?(delivered, &1))
  end

  defp mark_outbox_fully_delivered(outbox) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    outbox
    |> FederationOutboxEvent.changeset(%{
      status: "delivered",
      dispatched_at: now,
      delivered_domains: outbox.target_domains,
      next_retry_at: now,
      last_error: nil
    })
    |> Repo.update()

    :delivered
  end

  defp deliver_outbox_domain_batch(outbox, domain, context) do
    normalized_domain = String.downcase(domain)

    case call(context, :outgoing_peer, [normalized_domain]) do
      nil ->
        batch_rows = outbox_batch_for_domain(outbox, normalized_domain, context)

        Enum.each(
          batch_rows,
          &record_outbox_domain_failure(&1, normalized_domain, :unknown_peer, context)
        )

        {:error, :unknown_peer}

      peer ->
        batch_rows = outbox_batch_for_domain(outbox, normalized_domain, context)
        peer_batch_limit = call(context, :peer_batch_limit, [peer])
        {supported_rows, unsupported_rows} = split_supported_rows(batch_rows, peer)

        Enum.each(unsupported_rows, &record_outbox_domain_success(&1, normalized_domain))

        supported_rows
        |> Enum.chunk_every(peer_batch_limit)
        |> Enum.reduce_while(:ok, fn row_chunk, :ok ->
          events = Enum.map(row_chunk, & &1.payload)

          case push_event_batch_to_peer(peer, events, context) do
            {:ok, results} ->
              case apply_outbox_batch_results(row_chunk, normalized_domain, results, context) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, reason} ->
              Enum.each(
                row_chunk,
                &record_outbox_domain_failure(&1, normalized_domain, reason, context)
              )

              {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp outbox_batch_for_domain(outbox, domain, context) do
    sibling_limit = max(call(context, :delivery_batch_size, []) - 1, 0)
    now = DateTime.utc_now()

    siblings =
      if sibling_limit > 0 do
        from(o in FederationOutboxEvent,
          where:
            o.id != ^outbox.id and o.status == "pending" and o.attempt_count < o.max_attempts and
              o.next_retry_at <= ^now and
              fragment("? = ANY(?)", ^domain, o.target_domains) and
              not fragment("? = ANY(?)", ^domain, o.delivered_domains),
          order_by: [asc: o.id],
          limit: ^sibling_limit,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()
      else
        []
      end

    ([outbox] ++ siblings)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp apply_outbox_batch_results(batch_rows, domain, results, context) do
    results_by_event_id =
      results
      |> Enum.filter(&is_map/1)
      |> Map.new(fn result ->
        {result["event_id"],
         call(context, :normalize_optional_string, [result["status"]]) || "missing"}
      end)

    failures =
      Enum.reduce(batch_rows, [], fn row, acc ->
        status = Map.get(results_by_event_id, row.event_id, "missing")

        if Transport.event_result_success?(
             %{"status" => status},
             Map.fetch!(context, :successful_delivery_statuses)
           ) do
          record_outbox_domain_success(row, domain)
          acc
        else
          record_outbox_domain_failure(row, domain, {:remote_status, status}, context)
          [{row.event_id, status} | acc]
        end
      end)

    if failures == [] do
      :ok
    else
      {:error, {:partial_batch_failure, Enum.reverse(failures)}}
    end
  end

  defp record_outbox_domain_success(outbox, domain) do
    case Repo.get(FederationOutboxEvent, outbox.id) do
      %FederationOutboxEvent{} = current ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        delivered_domains = Enum.uniq((current.delivered_domains || []) ++ [domain])
        delivered_all? = Enum.sort(delivered_domains) == Enum.sort(current.target_domains || [])

        attrs =
          %{
            delivered_domains: delivered_domains,
            attempt_count: current.attempt_count + 1,
            next_retry_at: now,
            last_error: nil
          }
          |> maybe_put_delivered_status(delivered_all?, now)

        current
        |> FederationOutboxEvent.changeset(attrs)
        |> Repo.update()

      _ ->
        :ok
    end
  end

  defp record_outbox_domain_failure(outbox, domain, reason, context) do
    case Repo.get(FederationOutboxEvent, outbox.id) do
      %FederationOutboxEvent{} = current ->
        attempt_count = current.attempt_count + 1
        exhausted = attempt_count >= current.max_attempts
        backoff_seconds = call(context, :outbox_backoff_seconds, [attempt_count])
        next_retry_at = DateTime.add(DateTime.utc_now(), backoff_seconds, :second)

        current
        |> FederationOutboxEvent.changeset(%{
          status: if(exhausted, do: "failed", else: "pending"),
          attempt_count: attempt_count,
          next_retry_at: next_retry_at,
          last_error: merge_outbox_error(current.last_error, domain, reason, context)
        })
        |> Repo.update()

      _ ->
        :ok
    end
  end

  defp maybe_put_delivered_status(attrs, true, now) do
    Map.merge(attrs, %{status: "delivered", dispatched_at: now})
  end

  defp maybe_put_delivered_status(attrs, false, _now) do
    Map.put(attrs, :status, "pending")
  end

  defp merge_outbox_error(existing, domain, reason, context) do
    latest = "#{domain}: #{inspect(reason)}"

    case call(context, :normalize_optional_string, [existing]) do
      nil -> latest
      prior -> prior <> "; " <> latest
    end
  end

  defp event_transport_order(peer, context) when is_map(peer) do
    Transport.event_transport_order(peer, call(context, :transport_profiles_document, []))
  end

  defp event_transport_order(_peer, _context),
    do: ["events_batch_cbor", "events_batch_json", "events_json"]

  defp ephemeral_transport_order(peer, context) when is_map(peer) do
    Transport.ephemeral_transport_order(peer, call(context, :transport_profiles_document, []))
  end

  defp ephemeral_transport_order(_peer, _context),
    do: ["events_batch_cbor", "events_batch_json", "events_json"]

  defp split_supported_rows(batch_rows, peer) when is_list(batch_rows) and is_map(peer) do
    Enum.split_with(batch_rows, fn row ->
      Transport.peer_supports_event_type?(
        peer,
        row.event_type || get_in(row.payload, ["event_type"])
      )
    end)
  end

  defp split_supported_rows(batch_rows, _peer), do: {batch_rows, []}

  defp push_event_batch_via_transport(peer, events, "session_websocket", context) do
    if call(context, :peer_supports, [peer, "session_transport", false]) &&
         is_binary(call(context, :outbound_session_websocket_url, [peer])) do
      push_event_batch_over_session(peer, events, context)
    else
      {:skip, :unsupported_transport_profile}
    end
  end

  defp push_event_batch_via_transport(peer, events, "events_batch_cbor", context) do
    if call(context, :peer_supports, [
         peer,
         "binary_event_batches",
         call(context, :peer_configured, [peer])
       ]) &&
         call(context, :peer_supports, [peer, "batched_event_delivery", true]) &&
         is_binary(call(context, :outbound_events_batch_url, [peer])) do
      push_event_batch_request(peer, events, :cbor, context)
    else
      {:skip, :unsupported_transport_profile}
    end
  end

  defp push_event_batch_via_transport(peer, events, "events_batch_json", context) do
    if call(context, :peer_supports, [peer, "batched_event_delivery", true]) &&
         is_binary(call(context, :outbound_events_batch_url, [peer])) do
      push_event_batch_request(peer, events, :json, context)
    else
      {:skip, :unsupported_transport_profile}
    end
  end

  defp push_event_batch_via_transport(peer, events, "events_json", context) do
    push_event_individual_to_peer(peer, events, context)
  end

  defp push_event_batch_via_transport(_peer, _events, _transport, _context),
    do: {:skip, :unsupported_transport_profile}

  defp push_ephemeral_batch_via_transport(peer, items, "session_websocket", context) do
    if call(context, :peer_supports, [peer, "session_transport", false]) &&
         is_binary(call(context, :outbound_session_websocket_url, [peer])) do
      push_ephemeral_batch_over_session(peer, items, context)
    else
      {:skip, :unsupported_transport_profile}
    end
  end

  defp push_ephemeral_batch_via_transport(peer, items, "events_batch_cbor", context) do
    if call(context, :peer_supports, [
         peer,
         "ephemeral_lane",
         call(context, :peer_configured, [peer])
       ]) &&
         call(context, :peer_supports, [
           peer,
           "binary_event_batches",
           call(context, :peer_configured, [peer])
         ]) &&
         is_binary(call(context, :outbound_ephemeral_url, [peer])) do
      push_ephemeral_batch_request(peer, items, :cbor, context)
    else
      {:skip, :unsupported_transport_profile}
    end
  end

  defp push_ephemeral_batch_via_transport(peer, items, "events_batch_json", context) do
    if call(context, :peer_supports, [
         peer,
         "ephemeral_lane",
         call(context, :peer_configured, [peer])
       ]) &&
         is_binary(call(context, :outbound_ephemeral_url, [peer])) do
      push_ephemeral_batch_request(peer, items, :json, context)
    else
      {:skip, :unsupported_transport_profile}
    end
  end

  defp push_ephemeral_batch_via_transport(peer, items, "events_json", context) do
    push_ephemeral_items_as_events(peer, items, context)
  end

  defp push_ephemeral_batch_via_transport(_peer, _items, _transport, _context),
    do: {:skip, :unsupported_transport_profile}

  defp push_event_batch_request(peer, events, format, context) when format in [:cbor, :json] do
    path = "/_arblarg/events/batch"
    url = call(context, :outbound_events_batch_url, [peer])

    payload = %{
      "version" => 1,
      "batch_id" => Ecto.UUID.generate(),
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "events" => events
    }

    {body, content_type} =
      case format do
        :cbor -> {CBOR.encode(payload), @cbor_batch_content_type}
        :json -> {Jason.encode!(payload), "application/json"}
      end

    headers =
      call(context, :signed_headers, [peer, "POST", path, "", body])
      |> put_header("content-type", content_type)
      |> put_header("accept", content_type)

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: call(context, :delivery_timeout_ms, []),
           pool_timeout: 5_000
         ) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case decode_batch_response(response_body, content_type) do
          {:ok, %{"results" => results}} when is_list(results) ->
            {:ok, results}

          _ ->
            {:ok, Enum.map(events, &%{"event_id" => &1["event_id"], "status" => "applied"})}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, call(context, :truncate, [response_body])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_event_individual_to_peer(peer, events, context) when is_list(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, results} ->
      case push_single_event_to_peer(peer, event, context) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp push_single_event_to_peer(peer, event, context) when is_map(event) do
    path = "/_arblarg/events"
    url = call(context, :outbound_events_url, [peer])
    body = Jason.encode!(event)

    headers =
      call(context, :signed_headers, [peer, "POST", path, "", body])
      |> put_header("content-type", "application/json")
      |> put_header("accept", "application/json")

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: call(context, :delivery_timeout_ms, []),
           pool_timeout: 5_000
         ) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, %{"status" => event_status}} ->
            {:ok, %{"event_id" => event["event_id"], "status" => event_status}}

          _ ->
            {:ok, %{"event_id" => event["event_id"], "status" => "applied"}}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, call(context, :truncate, [response_body])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_ephemeral_batch_request(peer, items, format, context) when format in [:cbor, :json] do
    path = "/_arblarg/ephemeral"
    url = call(context, :outbound_ephemeral_url, [peer])

    payload = %{
      "version" => 1,
      "batch_id" => Ecto.UUID.generate(),
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "items" => items
    }

    {body, content_type} =
      case format do
        :cbor -> {CBOR.encode(payload), @ephemeral_item_content_type}
        :json -> {Jason.encode!(payload), "application/json"}
      end

    headers =
      call(context, :signed_headers, [peer, "POST", path, "", body])
      |> put_header("content-type", content_type)
      |> put_header("accept", content_type)

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: call(context, :delivery_timeout_ms, []),
           pool_timeout: 5_000
         ) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, call(context, :truncate, [response_body])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_event_batch_over_session(peer, events, context) when is_list(events) do
    grouped_events =
      events
      |> Enum.group_by(& &1["stream_id"])
      |> Enum.reject(fn {stream_id, stream_events} ->
        !is_binary(stream_id) or stream_id == "" or stream_events == []
      end)

    grouped_events
    |> Task.async_stream(
      fn {stream_id, stream_events} ->
        payload = %{
          "version" => 1,
          "delivery_id" => Ecto.UUID.generate(),
          "stream_id" => stream_id,
          "events" => stream_events
        }

        case FederationSessionClient.send_delivery(peer, "stream_batch", payload,
               timeout: call(context, :delivery_timeout_ms, [])
             ) do
          {:ok, %{"results" => results}} when is_list(results) ->
            {:ok, results}

          {:ok, _payload} ->
            {:ok,
             Enum.map(stream_events, &%{"event_id" => &1["event_id"], "status" => "applied"})}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      timeout: call(context, :delivery_timeout_ms, []) + 1_000,
      max_concurrency:
        max(min(length(grouped_events), call(context, :delivery_concurrency, [])), 1),
      ordered: false
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, results}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ results}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp push_ephemeral_batch_over_session(peer, items, context) when is_list(items) do
    payload = %{"version" => 1, "delivery_id" => Ecto.UUID.generate(), "items" => items}

    case FederationSessionClient.send_delivery(peer, "deliver_ephemeral", payload,
           timeout: call(context, :delivery_timeout_ms, [])
         ) do
      {:ok, %{"results" => results}} when is_list(results) ->
        if Enum.all?(results, &event_result_success?(&1, context)) do
          :ok
        else
          {:error, :ephemeral_fallback_failed}
        end

      {:ok, _payload} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_ephemeral_items_as_events(peer, items, context) when is_list(items) do
    with {:ok, events} <- durable_events_from_ephemeral_items(items, context),
         {:ok, results} <- push_event_batch_to_peer(peer, events, context),
         true <- Enum.all?(results, &event_result_success?(&1, context)) do
      :ok
    else
      false -> {:error, :ephemeral_fallback_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_events_from_ephemeral_items(items, context) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case durable_event_from_ephemeral_item(item, context) do
        {:ok, event} -> {:cont, {:ok, acc ++ [event]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp durable_event_from_ephemeral_item(item, context) when is_map(item) do
    payload = item["payload"] || %{}
    event_type = ArblargSDK.canonical_event_type(item["event_type"])

    with true <- event_type in ["presence.update", "typing.start", "typing.stop"],
         stream_id when is_binary(stream_id) <-
           call(context, :ephemeral_stream_id, [event_type, payload]) do
      sequence = call(context, :next_outbound_sequence, [stream_id])
      {:ok, call(context, :event_envelope, [event_type, stream_id, sequence, payload])}
    else
      false -> {:error, :unsupported_event_type}
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp durable_event_from_ephemeral_item(_item, _context), do: {:error, :invalid_payload}

  defp event_result_success?(result, context) do
    Transport.event_result_success?(result, Map.fetch!(context, :successful_delivery_statuses))
  end

  defp decode_batch_response(body, content_type)
       when is_binary(body) and is_binary(content_type) do
    case String.downcase(content_type) do
      @cbor_batch_content_type ->
        decode_cbor(body)

      @ephemeral_item_content_type ->
        decode_cbor(body)

      _ ->
        Jason.decode(body)
    end
  end

  defp decode_batch_response(body, _content_type), do: Jason.decode(body)

  defp decode_cbor(body) when is_binary(body) do
    case CBOR.decode(body) do
      {:ok, decoded, ""} -> {:ok, decoded}
      {:ok, _decoded, _rest} -> {:error, :invalid_payload}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp decode_cbor(_body), do: {:error, :invalid_payload}

  defp put_header(headers, key, value) when is_list(headers) do
    normalized_key = String.downcase(key)

    filtered =
      Enum.reject(headers, fn {header_key, _} -> String.downcase(header_key) == normalized_key end)

    filtered ++ [{key, value}]
  end

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
