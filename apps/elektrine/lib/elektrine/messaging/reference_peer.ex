defmodule Elektrine.Messaging.ReferencePeer do
  @moduledoc """
  Minimal independent Arblarg reference peer used for interop smoke tests.

  This module intentionally does not depend on the federation persistence layer.
  It maintains its own event ordering, deduplication, and replay state in memory.
  """

  alias Elektrine.Messaging.ReferencePeerProtocol

  defstruct domain: nil,
            key_id: "ref-k1",
            private_key: nil,
            public_key: nil,
            features: %{},
            positions: %{},
            events: %{},
            seen_event_ids: MapSet.new()

  @type t :: %__MODULE__{}

  def new(opts \\ []) when is_list(opts) do
    domain = Keyword.get(opts, :domain, "reference.test")
    key_id = Keyword.get(opts, :key_id, "ref-k1")
    secret = Keyword.get(opts, :secret, "#{domain}:#{key_id}")
    {public_key, private_key} = ReferencePeerProtocol.derive_keypair_from_secret(secret)

    %__MODULE__{
      domain: domain,
      key_id: key_id,
      private_key: private_key,
      public_key: public_key,
      features: Map.merge(default_features(), Keyword.get(opts, :features, %{}))
    }
  end

  def discovery_document(%__MODULE__{} = peer, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "https://#{peer.domain}")

    session_url =
      Keyword.get(opts, :session_websocket, "wss://#{peer.domain}/federation/messaging/session")

    unsigned = %{
      "protocol" => ReferencePeerProtocol.protocol_name(),
      "protocol_id" => ReferencePeerProtocol.protocol_id(),
      "protocol_labels" => [ReferencePeerProtocol.protocol_label()],
      "default_protocol_label" => ReferencePeerProtocol.protocol_label(),
      "protocol_versions" => [ReferencePeerProtocol.protocol_version()],
      "default_protocol_version" => ReferencePeerProtocol.protocol_version(),
      "version" => 1,
      "domain" => peer.domain,
      "identity" => %{
        "algorithm" => ReferencePeerProtocol.signature_algorithm(),
        "current_key_id" => peer.key_id,
        "keys" => [
          %{
            "id" => peer.key_id,
            "algorithm" => ReferencePeerProtocol.signature_algorithm(),
            "public_key" => Base.url_encode64(peer.public_key, padding: false)
          }
        ]
      },
      "endpoints" => %{
        "well_known" => "#{base_url}/.well-known/arblarg",
        "well_known_versioned" =>
          "#{base_url}/.well-known/arblarg/#{ReferencePeerProtocol.protocol_version()}",
        "profiles" => "#{base_url}/federation/messaging/arblarg/profiles",
        "events" => "#{base_url}/federation/messaging/events",
        "events_batch" => "#{base_url}/federation/messaging/events/batch",
        "ephemeral" => "#{base_url}/federation/messaging/ephemeral",
        "sync" => "#{base_url}/federation/messaging/sync",
        "stream_events" => "#{base_url}/federation/messaging/streams/events",
        "session_websocket" => session_url,
        "public_servers" => "#{base_url}/federation/messaging/servers/public",
        "snapshot_template" => "#{base_url}/federation/messaging/servers/{server_id}/snapshot",
        "schema_template" => "#{base_url}/federation/messaging/arblarg/{version}/schemas/{name}",
        "schemas" =>
          "#{base_url}/federation/messaging/arblarg/#{ReferencePeerProtocol.protocol_version()}/schemas"
      },
      "features" => peer.features,
      "transport_profiles" => %{
        "preferred_order" => [
          "session_websocket",
          "events_batch_cbor",
          "events_batch_json",
          "events_json"
        ],
        "fallback_order" => [
          "session_websocket",
          "events_batch_cbor",
          "events_batch_json",
          "events_json"
        ],
        "session_websocket" => %{
          "mode" => "preferred",
          "framing" => "arblarg_websocket_stream_session",
          "request_path" => "/federation/messaging/session",
          "subprotocol" => "arblarg.session.v1",
          "encodings" => ["json", "cbor"],
          "flow_control" => %{
            "max_inflight_batches" => 8,
            "max_inflight_events" => 256
          }
        }
      }
    }

    Map.put(unsigned, "signature", %{
      "algorithm" => ReferencePeerProtocol.signature_algorithm(),
      "key_id" => peer.key_id,
      "value" =>
        unsigned
        |> ReferencePeerProtocol.canonical_json_payload()
        |> ReferencePeerProtocol.sign_payload(peer.private_key)
    })
  end

  def key_lookup(%__MODULE__{} = peer, key_id) do
    if is_nil(key_id) or key_id == peer.key_id do
      [peer.public_key]
    else
      []
    end
  end

  def key_lookup_from_identity(%{"keys" => keys}) when is_list(keys) do
    fn requested_key_id ->
      keys
      |> Enum.filter(fn key ->
        is_nil(requested_key_id) or requested_key_id == key["id"]
      end)
      |> Enum.map(& &1["public_key"])
    end
  end

  def key_lookup_from_identity(_identity), do: fn _key_id -> [] end

  def signed_event(%__MODULE__{} = peer, event_type, stream_id, sequence, payload, opts \\ [])
      when is_binary(event_type) and is_binary(stream_id) and is_integer(sequence) and
             is_map(payload) and sequence > 0 do
    origin_domain = Keyword.get(opts, :origin_domain, peer.domain)
    event_id = Keyword.get(opts, :event_id, "evt-#{Ecto.UUID.generate()}")
    idempotency_key = Keyword.get(opts, :idempotency_key, "idem-#{Ecto.UUID.generate()}")
    sent_at = Keyword.get(opts, :sent_at, DateTime.utc_now() |> DateTime.truncate(:second))

    %{
      "protocol" => ReferencePeerProtocol.protocol_name(),
      "protocol_id" => ReferencePeerProtocol.protocol_id(),
      "protocol_label" => ReferencePeerProtocol.protocol_label(),
      "protocol_version" => ReferencePeerProtocol.protocol_version(),
      "event_id" => event_id,
      "event_type" => event_type,
      "origin_domain" => origin_domain,
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.to_iso8601(sent_at),
      "idempotency_key" => idempotency_key,
      "payload" => payload
    }
    |> ReferencePeerProtocol.sign_event_envelope(peer.key_id, peer.private_key)
  end

  def receive_event(%__MODULE__{} = peer, envelope, remote_key_lookup_fun)
      when is_function(remote_key_lookup_fun, 1) do
    with :ok <- ReferencePeerProtocol.validate_event_envelope(envelope),
         true <-
           ReferencePeerProtocol.verify_event_envelope_signature(envelope, remote_key_lookup_fun) do
      event_id = envelope["event_id"]
      origin_domain = envelope["origin_domain"]
      stream_id = envelope["stream_id"]
      sequence = envelope["sequence"]
      last_sequence = Map.get(peer.positions, stream_id, 0)
      dedupe_key = {origin_domain, event_id}

      cond do
        MapSet.member?(peer.seen_event_ids, dedupe_key) ->
          {:ok, peer, :duplicate}

        sequence <= last_sequence ->
          {:ok, peer, :stale}

        sequence > last_sequence + 1 ->
          {:error, :sequence_gap}

        true ->
          updated_peer = %{
            peer
            | positions: Map.put(peer.positions, stream_id, sequence),
              events: Map.update(peer.events, stream_id, [envelope], &(&1 ++ [envelope])),
              seen_event_ids: MapSet.put(peer.seen_event_ids, dedupe_key)
          }

          {:ok, updated_peer, :applied}
      end
    else
      false -> {:error, :invalid_event_signature}
      {:error, reason} -> {:error, reason}
    end
  end

  def receive_event_batch(%__MODULE__{} = peer, payload, remote_key_lookup_fun)
      when is_map(payload) and is_function(remote_key_lookup_fun, 1) do
    with batch_id when is_binary(batch_id) <- payload["batch_id"],
         events when is_list(events) <- payload["events"] do
      {updated_peer, results} =
        Enum.reduce(events, {peer, []}, fn event, {acc_peer, acc_results} ->
          case receive_event(acc_peer, event, remote_key_lookup_fun) do
            {:ok, next_peer, status} ->
              {next_peer,
               acc_results ++ [%{"event_id" => event["event_id"], "status" => to_string(status)}]}

            {:error, reason} ->
              {acc_peer,
               acc_results ++
                 [
                   %{
                     "event_id" => event["event_id"],
                     "status" => "error",
                     "code" => to_string(reason)
                   }
                 ]}
          end
        end)

      counts = summarize_result_counts(results)
      error_counts = summarize_result_errors(results)

      {:ok, updated_peer,
       %{
         "version" => 1,
         "batch_id" => batch_id,
         "event_count" => length(events),
         "counts" => counts,
         "error_counts" => error_counts,
         "results" => results
       }}
    else
      _ -> {:error, :invalid_batch}
    end
  end

  def export_stream_events(%__MODULE__{} = peer, stream_id, opts \\ [])
      when is_binary(stream_id) do
    after_sequence = Keyword.get(opts, :after_sequence, 0)
    limit = Keyword.get(opts, :limit, 128)

    events =
      peer.events
      |> Map.get(stream_id, [])
      |> Enum.filter(&(&1["sequence"] > after_sequence))
      |> Enum.take(limit)

    last_sequence = Map.get(peer.positions, stream_id, after_sequence)

    next_after_sequence =
      events |> List.last() |> then(&if(&1, do: &1["sequence"], else: after_sequence))

    %{
      "version" => 1,
      "stream_id" => stream_id,
      "after_sequence" => after_sequence,
      "next_after_sequence" => next_after_sequence,
      "last_sequence" => last_sequence,
      "has_more" => next_after_sequence < last_sequence,
      "events" => events
    }
  end

  def summary(%__MODULE__{} = peer) do
    event_count =
      peer.events
      |> Map.values()
      |> Enum.reduce(0, fn events, acc -> acc + length(events) end)

    %{
      domain: peer.domain,
      streams: map_size(peer.positions),
      events: event_count,
      trustable_features: peer.features
    }
  end

  defp default_features do
    %{
      "batched_event_delivery" => true,
      "stream_catch_up" => true,
      "compact_event_refs" => true,
      "binary_event_batches" => true,
      "read_cursors" => true,
      "ephemeral_lane" => true,
      "session_transport" => true,
      "dynamic_peer_discovery" => true,
      "open_domain_bootstrap" => true
    }
  end

  defp summarize_result_counts(results) when is_list(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      status =
        result["status"]
        |> to_string()
        |> String.split(":", parts: 2)
        |> List.first()

      Map.update(acc, status, 1, &(&1 + 1))
    end)
  end

  defp summarize_result_counts(_results), do: %{}

  defp summarize_result_errors(results) when is_list(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      case result["code"] do
        code when is_binary(code) ->
          Map.update(acc, code, 1, &(&1 + 1))

        _ ->
          acc
      end
    end)
  end

  defp summarize_result_errors(_results), do: %{}
end
