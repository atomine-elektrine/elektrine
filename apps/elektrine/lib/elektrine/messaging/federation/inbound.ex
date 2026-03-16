defmodule Elektrine.Messaging.Federation.Inbound do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK

  @presence_update_event_type ArblargSDK.canonical_event_type("presence.update")
  @typing_start_event_type ArblargSDK.canonical_event_type("typing.start")
  @typing_stop_event_type ArblargSDK.canonical_event_type("typing.stop")
  @dm_call_signal_event_type ArblargSDK.canonical_event_type("dm.call.signal")

  def normalize_incoming_batch_payload(%{"events" => events} = payload, context)
      when is_list(events) and is_map(context) do
    if length(events) <= call(context, :incoming_batch_limit, []) do
      batch_id = call(context, :normalize_optional_string, [payload["batch_id"]]) || Ecto.UUID.generate()
      {:ok, batch_id, events}
    else
      {:error, :batch_limit_exceeded}
    end
  end

  def normalize_incoming_batch_payload(events, context) when is_list(events) and is_map(context) do
    if length(events) <= call(context, :incoming_batch_limit, []) do
      {:ok, Ecto.UUID.generate(), events}
    else
      {:error, :batch_limit_exceeded}
    end
  end

  def normalize_incoming_batch_payload(_payload, _context), do: {:error, :invalid_payload}

  def normalize_incoming_ephemeral_payload(%{"items" => items} = payload, context)
      when is_list(items) and is_map(context) do
    if length(items) <= call(context, :incoming_ephemeral_limit, []) do
      batch_id = call(context, :normalize_optional_string, [payload["batch_id"]]) || Ecto.UUID.generate()
      {:ok, batch_id, items}
    else
      {:error, :ephemeral_limit_exceeded}
    end
  end

  def normalize_incoming_ephemeral_payload(items, context)
      when is_list(items) and is_map(context) do
    if length(items) <= call(context, :incoming_ephemeral_limit, []) do
      {:ok, Ecto.UUID.generate(), items}
    else
      {:error, :ephemeral_limit_exceeded}
    end
  end

  def normalize_incoming_ephemeral_payload(_payload, _context), do: {:error, :invalid_payload}

  def normalize_session_stream_batch_payload(payload, expected_delivery_id, context)
      when is_map(payload) and is_map(context) do
    events = payload["events"]
    delivery_id = call(context, :normalize_optional_string, [payload["delivery_id"]])
    stream_id = call(context, :normalize_optional_string, [payload["stream_id"]])
    version = call(context, :parse_int, [payload["version"], 0])

    cond do
      version != 1 ->
        {:error, :unsupported_version}

      !is_list(events) ->
        {:error, :invalid_payload}

      events == [] ->
        {:error, :invalid_payload}

      length(events) > call(context, :incoming_batch_limit, []) ->
        {:error, :batch_limit_exceeded}

      !is_binary(delivery_id) ->
        {:error, :invalid_payload}

      is_binary(expected_delivery_id) and delivery_id != expected_delivery_id ->
        {:error, :invalid_payload}

      !is_binary(stream_id) ->
        {:error, :invalid_payload}

      Enum.any?(events, &(call(context, :normalize_optional_string, [&1["stream_id"]]) != stream_id)) ->
        {:error, :invalid_payload}

      true ->
        {:ok, delivery_id, events}
    end
  end

  def normalize_session_stream_batch_payload(_payload, _expected_delivery_id, _context),
    do: {:error, :invalid_payload}

  def normalize_session_ephemeral_batch_payload(payload, expected_delivery_id, context)
      when is_map(payload) and is_map(context) do
    items = payload["items"]
    delivery_id = call(context, :normalize_optional_string, [payload["delivery_id"]])
    version = call(context, :parse_int, [payload["version"], 0])

    cond do
      version != 1 ->
        {:error, :unsupported_version}

      !is_list(items) ->
        {:error, :invalid_payload}

      items == [] ->
        {:error, :invalid_payload}

      length(items) > call(context, :incoming_ephemeral_limit, []) ->
        {:error, :ephemeral_limit_exceeded}

      !is_binary(delivery_id) ->
        {:error, :invalid_payload}

      is_binary(expected_delivery_id) and delivery_id != expected_delivery_id ->
        {:error, :invalid_payload}

      true ->
        {:ok, delivery_id, items}
    end
  end

  def normalize_session_ephemeral_batch_payload(_payload, _expected_delivery_id, _context),
    do: {:error, :invalid_payload}

  def process_incoming_event_result(event, remote_domain, context)
      when is_map(event) and is_binary(remote_domain) and is_map(context) do
    case call(context, :receive_event, [event, remote_domain]) do
      {:ok, result} ->
        %{"event_id" => event["event_id"], "status" => Atom.to_string(result)}

      {:error, :sequence_gap} ->
        recovery_result =
          case call(context, :recover_sequence_gap, [event, remote_domain]) do
            {:ok, :recovered_via_stream} -> "recovered_via_stream"
            {:ok, :recovered} -> "recovered_via_snapshot"
            {:ok, :recovered_via_snapshot} -> "recovered_via_snapshot"
            {:error, reason} -> error_result(event["event_id"], reason, context)
          end

        case recovery_result do
          %{} = result -> result
          status -> %{"event_id" => event["event_id"], "status" => status}
        end

      {:error, reason} ->
        error_result(event["event_id"], reason, context)
    end
  end

  def process_incoming_ephemeral_result(item, remote_domain, context)
      when is_map(item) and is_binary(remote_domain) and is_map(context) do
    item_payload = item["payload"] || %{}
    event_type = ArblargSDK.canonical_event_type(item["event_type"])

    result =
      cond do
        !is_binary(item["event_type"]) ->
          {:error, :invalid_payload}

        call(context, :normalize_optional_string, [item["origin_domain"]]) not in [nil, remote_domain] ->
          {:error, :origin_domain_mismatch}

        event_type not in [
          @presence_update_event_type,
          "presence.update",
          @typing_start_event_type,
          "typing.start",
          @typing_stop_event_type,
          "typing.stop",
          @dm_call_signal_event_type,
          "dm.call.signal"
        ] ->
          {:error, :unsupported_event_type}

        true ->
          case ArblargSDK.validate_event_payload(event_type, item_payload) do
            :ok ->
              with :ok <-
                     call(context, :validate_origin_bound_actors_in_event_data, [
                       event_type,
                       item_payload,
                       remote_domain
                     ]),
                   :ok <-
                     call(context, :validate_origin_owned_identifiers_in_event_data, [
                       event_type,
                       item_payload,
                       remote_domain
                     ]) do
                call(context, :apply_event, [event_type, item_payload, remote_domain])
              end

            {:error, reason} ->
              {:error, reason}
          end
      end

    case result do
      :ok ->
        %{"event_type" => item["event_type"], "status" => "applied"}

      {:error, reason} ->
        error_result(item["event_type"], reason, context, "event_type")
    end
  end

  def batch_summary(batch_id, results) when is_list(results) do
    %{
      "version" => 1,
      "batch_id" => batch_id,
      "event_count" => length(results),
      "counts" => summarize_result_counts(results),
      "error_counts" => summarize_result_errors(results),
      "results" => results
    }
  end

  def batch_summary(batch_id, _results) do
    %{
      "version" => 1,
      "batch_id" => batch_id,
      "event_count" => 0,
      "counts" => %{},
      "error_counts" => %{},
      "results" => []
    }
  end

  defp summarize_result_counts(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      Map.update(acc, result["status"], 1, &(&1 + 1))
    end)
  end

  defp summarize_result_errors(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      case result["code"] do
        code when is_binary(code) ->
          Map.update(acc, code, 1, &(&1 + 1))

        _ ->
          acc
      end
    end)
  end

  defp error_result(identifier, reason, context, identifier_key \\ "event_id") do
    %{
      identifier_key => identifier,
      "status" => "error",
      "code" => call(context, :error_code, [reason])
    }
  end

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
