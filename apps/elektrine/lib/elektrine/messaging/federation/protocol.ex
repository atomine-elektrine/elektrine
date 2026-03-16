defmodule Elektrine.Messaging.Federation.Protocol do
  @moduledoc false

  alias Elektrine.Messaging.ArblargProfiles
  alias Elektrine.Messaging.ArblargSDK

  def local_discovery_document(version, context) when is_binary(version) and is_map(context) do
    unsigned = %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_labels" => [ArblargSDK.protocol_label()],
      "default_protocol_label" => ArblargSDK.protocol_label(),
      "protocol_versions" => [ArblargSDK.protocol_version()],
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "domain" => Map.get(context, :local_domain),
      "identity" => Map.get(context, :identity),
      "endpoints" =>
        discovery_endpoints(
          Map.get(context, :base_url),
          version,
          Map.get(context, :allow_insecure_transport, false)
        ),
      "features" => discovery_features(),
      "limits" => Map.get(context, :limits, %{}),
      "transport_profiles" =>
        transport_profiles_document(
          Map.get(context, :limits, %{}),
          Map.get(context, :cache_ttl_seconds, 0)
        ),
      "relay_transport" => %{
        "mode" => "optional",
        "community_hostable" => true,
        "official_operator" => Map.get(context, :official_relay_operator),
        "official_relays" => Map.get(context, :official_relays, [])
      }
    }

    sign_document(unsigned, Map.get(context, :sign_fun))
  end

  def arblarg_profiles_document(version, context) when is_binary(version) and is_map(context) do
    clock_skew_seconds = Map.get(context, :clock_skew_seconds)
    core_event_types = ArblargProfiles.core_event_types()
    extension_event_types = ArblargProfiles.extension_event_types()
    supported_event_types = ArblargSDK.supported_event_types()

    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_versions" => [ArblargSDK.protocol_version()],
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "profiles" => ArblargProfiles.profile_badges(),
      "compatibility_claims" => ArblargProfiles.passing_profile_claims(),
      "extensions" => ArblargProfiles.extension_registry(),
      "features" => profiles_features(),
      "security" => %{
        "request_signature" => %{
          "algorithm" => ArblargSDK.signature_algorithm(),
          "required" => true,
          "headers" => [
            "x-arblarg-domain",
            "x-arblarg-key-id",
            "x-arblarg-timestamp",
            "x-arblarg-content-digest",
            "x-arblarg-request-id",
            "x-arblarg-signature-algorithm",
            "x-arblarg-signature"
          ],
          "clock_skew_seconds" => clock_skew_seconds
        },
        "event_signature" => %{
          "algorithm" => ArblargSDK.signature_algorithm(),
          "field" => "signature",
          "required" => true
        },
        "discovery_signature" => %{
          "algorithm" => ArblargSDK.signature_algorithm(),
          "field" => "signature",
          "required" => true
        },
        "transport" => %{
          "tls_required" => true,
          "allow_insecure_http_for_testing" => Map.get(context, :allow_insecure_transport, false)
        }
      },
      "events" => %{
        "core" => core_event_types,
        "extensions" => extension_event_types,
        "supported" => supported_event_types,
        "ordering" => %{
          "cursor" => %{"field" => "sequence", "scope" => ["origin_domain", "stream_id"]},
          "idempotency" => %{"field" => "idempotency_key", "scope" => ["origin_domain"]},
          "retry" => %{"strategy" => "bounded_exponential_backoff", "deterministic" => true}
        }
      },
      "schemas" => discovery_schema_map(Map.get(context, :base_url), version),
      "relay_transport" => %{
        "mode" => "optional",
        "community_hostable" => true,
        "official_operator" => Map.get(context, :official_relay_operator),
        "official_relays" => Map.get(context, :official_relays, [])
      },
      "limits" => Map.get(context, :limits, %{}),
      "transport_profiles" =>
        transport_profiles_document(
          Map.get(context, :limits, %{}),
          Map.get(context, :cache_ttl_seconds, 0)
        ),
      "wire_contract" => %{
        "status" => "stable",
        "breaking_changes" => "disallowed_in_1_0",
        "change_policy" => "additive_only",
        "deprecation_policy" => "must_remain_compatible_with_1_0"
      },
      "endpoints" =>
        discovery_endpoints(
          Map.get(context, :base_url),
          version,
          Map.get(context, :allow_insecure_transport, false)
        ),
      "conformance" => %{
        "gate" => "hard",
        "suite_version" => ArblargProfiles.conformance_suite_version(),
        "required_profile" => ArblargProfiles.core_profile_id(),
        "test_command" => ArblargProfiles.conformance_test_command()
      }
    }
  end

  def discovery_limits_for_transport(context) when is_map(context) do
    Map.get(context, :limits, %{})
  end

  def transport_profiles_for_transport(context) when is_map(context) do
    transport_profiles_document(
      Map.get(context, :limits, %{}),
      Map.get(context, :cache_ttl_seconds, 0)
    )
  end

  def session_flow_control_for_transport(context) when is_map(context) do
    session_flow_control_document(Map.get(context, :limits, %{}))
  end

  def discovery_endpoints(base_url, version, allow_insecure_transport)
      when is_binary(base_url) and is_binary(version) do
    endpoints = %{
      "well_known" => "#{base_url}/.well-known/_arblarg",
      "well_known_versioned" => "#{base_url}/.well-known/_arblarg/{version}",
      "profiles" => "#{base_url}/_arblarg/profiles",
      "events" => "#{base_url}/_arblarg/events",
      "events_batch" => "#{base_url}/_arblarg/events/batch",
      "ephemeral" => "#{base_url}/_arblarg/ephemeral",
      "sync" => "#{base_url}/_arblarg/sync",
      "stream_events" => "#{base_url}/_arblarg/streams/events",
      "public_servers" => "#{base_url}/_arblarg/servers/public",
      "snapshot_template" => "#{base_url}/_arblarg/servers/{server_id}/snapshot",
      "schema_template" => "#{base_url}/_arblarg/{version}/schemas/{name}",
      "schemas" => "#{base_url}/_arblarg/#{version}/schemas"
    }

    case session_websocket_url(base_url, allow_insecure_transport) do
      url when is_binary(url) -> Map.put(endpoints, "session_websocket", url)
      _ -> endpoints
    end
  end

  def discovery_endpoints(_base_url, _version, _allow_insecure_transport), do: %{}

  def transport_profiles_document(limits, cache_ttl_seconds)
      when is_map(limits) and is_integer(cache_ttl_seconds) do
    %{
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
      "cache_ttl_seconds" => cache_ttl_seconds,
      "downgrade_http_statuses" => [404, 406, 410, 415, 426, 501],
      "session_websocket" => %{
        "mode" => "optional",
        "framing" => "arblarg_websocket_stream_session",
        "request_path" => "/_arblarg/session",
        "subprotocol" => "arblarg.session.v1",
        "encodings" => ["json", "cbor"],
        "flow_control" => session_flow_control_document(limits),
        "delivery_ops" => ["stream_batch", "deliver_ephemeral"],
        "control_ops" => ["events_batch", "ephemeral_batch", "stream_events", "snapshot", "ping"]
      }
    }
  end

  def transport_profiles_document(_limits, _cache_ttl_seconds), do: %{}

  def session_flow_control_document(limits) when is_map(limits) do
    %{
      "mode" => "ack_window",
      "max_inflight_batches" => Map.get(limits, "max_session_inflight_batches"),
      "max_inflight_events" => Map.get(limits, "max_session_inflight_events")
    }
  end

  def session_flow_control_document(_limits), do: %{}

  def discovery_schema_map(base_url, version) when is_binary(base_url) and is_binary(version) do
    schema_base = "#{base_url}/_arblarg/#{version}/schemas"

    schema_links =
      ArblargSDK.schema_bindings()
      |> Enum.reduce(%{}, fn {schema_key, schema_name}, acc ->
        Map.put(acc, schema_key, "#{schema_base}/#{schema_name}")
      end)

    Map.merge(%{"version" => version, "base_url" => schema_base}, schema_links)
  end

  def discovery_schema_map(_base_url, _version), do: %{}

  defp sign_document(document, fun) when is_function(fun, 1), do: fun.(document)
  defp sign_document(document, _fun), do: document

  defp session_websocket_url(base_url, allow_insecure_transport) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: "https"} = uri ->
        %{uri | scheme: "wss", path: "/_arblarg/session"}
        |> URI.to_string()

      %URI{scheme: "http"} = uri ->
        if allow_insecure_transport do
          %{uri | scheme: "ws", path: "/_arblarg/session"}
          |> URI.to_string()
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp session_websocket_url(_base_url, _allow_insecure_transport), do: nil

  defp discovery_features do
    %{
      "relay_transport" => true,
      "batched_event_delivery" => true,
      "stream_catch_up" => true,
      "compact_event_refs" => true,
      "binary_event_batches" => true,
      "read_cursors" => true,
      "ephemeral_lane" => true,
      "structured_error_codes" => true,
      "origin_owned_identifiers" => true,
      "signed_snapshots" => true,
      "snapshot_governance" => true,
      "snapshot_message_deletions" => true,
      "snapshot_reactions" => true,
      "snapshot_read_cursors" => true,
      "snapshot_extensions" => true,
      "canonical_extension_event_types" => true,
      "session_transport" => true,
      "dynamic_peer_discovery" => true,
      "open_domain_bootstrap" => true,
      "key_continuity_tracking" => true,
      "key_continuity_quarantine" => true
    }
  end

  defp profiles_features do
    %{
      "event_federation" => true,
      "snapshot_sync" => true,
      "batched_event_delivery" => true,
      "stream_catch_up" => true,
      "ordered_streams" => true,
      "idempotent_events" => true,
      "relay_transport" => true,
      "event_signature_envelope" => true,
      "request_replay_protection" => true,
      "strict_profiles" => true,
      "extension_negotiation" => true,
      "compact_event_refs" => true,
      "binary_event_batches" => true,
      "read_cursors" => true,
      "ephemeral_lane" => true,
      "ephemeral_presence" => true,
      "ephemeral_typing" => true,
      "structured_error_codes" => true,
      "origin_owned_identifiers" => true,
      "signed_snapshots" => true,
      "snapshot_governance" => true,
      "snapshot_message_deletions" => true,
      "snapshot_reactions" => true,
      "snapshot_read_cursors" => true,
      "snapshot_extensions" => true,
      "canonical_extension_event_types" => true,
      "session_transport" => true,
      "dynamic_peer_discovery" => true,
      "open_domain_bootstrap" => true,
      "discovery_document_signature" => true,
      "dns_identity_proof" => true,
      "configured_trust_anchors" => true,
      "key_continuity_tracking" => true,
      "key_continuity_quarantine" => true,
      "wire_contract_frozen" => true
    }
  end
end
