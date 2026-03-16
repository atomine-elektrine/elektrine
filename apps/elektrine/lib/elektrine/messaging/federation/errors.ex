defmodule Elektrine.Messaging.Federation.Errors do
  @moduledoc false

  @error_codes %{
    missing_domain: "missing_domain",
    missing_key_id: "missing_key_id",
    missing_timestamp: "missing_timestamp",
    missing_content_digest: "missing_content_digest",
    missing_request_id: "missing_request_id",
    missing_signature_algorithm: "missing_signature_algorithm",
    missing_signature: "missing_signature",
    invalid_signature_algorithm: "invalid_signature_algorithm",
    invalid_signature: "invalid_signature",
    invalid_timestamp: "invalid_timestamp",
    invalid_content_digest: "invalid_content_digest",
    replayed_request: "replayed_request",
    unknown_peer: "unknown_peer",
    invalid_payload: "invalid_payload",
    invalid_json: "invalid_json",
    invalid_event_payload: "invalid_event_payload",
    invalid_snapshot_signature: "invalid_snapshot_signature",
    invalid_snapshot_governance: "invalid_snapshot_governance",
    invalid_snapshot_response: "invalid_snapshot_response",
    invalid_stream_replay_response: "invalid_stream_replay_response",
    invalid_discovery_document: "invalid_discovery_document",
    invalid_discovery_signature: "invalid_discovery_signature",
    invalid_discovery_response: "invalid_discovery_response",
    invalid_discovery_url: "invalid_discovery_url",
    invalid_session_frame: "invalid_session_frame",
    invalid_session_handshake: "invalid_session_handshake",
    invalid_session_endpoint: "invalid_session_endpoint",
    invalid_server_id: "invalid_server_id",
    unsupported_protocol: "unsupported_protocol",
    missing_base_url: "missing_base_url",
    domain_mismatch: "domain_mismatch",
    origin_domain_mismatch: "origin_domain_mismatch",
    origin_identifier_host_mismatch: "origin_identifier_host_mismatch",
    origin_actor_host_mismatch: "origin_actor_host_mismatch",
    origin_stream_host_mismatch: "origin_stream_host_mismatch",
    federation_origin_conflict: "federation_origin_conflict",
    not_authorized_for_room: "not_authorized_for_room",
    snapshot_unavailable: "snapshot_unavailable",
    stream_recovery_failed: "stream_recovery_failed",
    sequence_gap: "sequence_gap",
    batch_limit_exceeded: "batch_limit_exceeded",
    ephemeral_limit_exceeded: "ephemeral_limit_exceeded",
    snapshot_limit_exceeded: "snapshot_limit_exceeded",
    unsupported_transport_profile: "unsupported_transport_profile",
    no_compatible_transport: "no_compatible_transport",
    session_transport_unavailable: "session_transport_unavailable",
    session_transport_failed: "session_transport_failed",
    session_closed: "session_closed",
    session_timeout: "session_timeout",
    unsupported_event_type: "unsupported_event_type",
    unsupported_operation: "unsupported_operation",
    bootstrap_trust_not_verified: "bootstrap_trust_not_verified",
    identity_anchor_mismatch: "identity_anchor_mismatch",
    identity_dns_proof_failed: "identity_dns_proof_failed",
    discovery_unavailable: "discovery_unavailable",
    internal_error: "internal_error"
  }

  @error_reasons Map.new(@error_codes, fn {reason, code} -> {code, reason} end)

  def error_code({:post_recovery_apply_failed, reason}), do: error_code(reason)
  def error_code({:http_error, _status, _body}), do: "upstream_http_error"
  def error_code({:http_error, _status}), do: "upstream_http_error"
  def error_code({:unknown_peer, _domain}), do: "unknown_peer"
  def error_code({:invalid_json, _reason}), do: "invalid_json"
  def error_code({:session_connect_failed, _reason}), do: "session_transport_failed"
  def error_code({:session_receive_failed, _reason}), do: "session_transport_failed"
  def error_code({:session_handshake_failed, _reason}), do: "session_transport_failed"
  def error_code({:invalid_discovery_fetcher_response, _other}), do: "invalid_discovery_response"

  def error_code(reason) when is_atom(reason) do
    Map.get(@error_codes, reason, "internal_error")
  end

  def error_code(_reason), do: "internal_error"

  def error_reason("upstream_http_error"), do: {:http_error, 502}

  def error_reason(code) when is_binary(code) do
    Map.get(@error_reasons, code)
  end

  def error_reason(_code), do: nil
end
