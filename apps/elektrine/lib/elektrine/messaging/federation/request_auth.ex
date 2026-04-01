defmodule Elektrine.Messaging.Federation.RequestAuth do
  @moduledoc false

  alias Elektrine.Messaging.Federation.{Auth, Contexts, Discovery, Peers, Runtime, Utils}

  def signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest \\ "",
        request_id \\ ""
      ) do
    Auth.signature_payload(
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id
    )
  end

  def body_digest(body), do: Auth.body_digest(body)

  def sign_payload(payload, signing_material), do: Auth.sign_payload(payload, signing_material)

  def valid_timestamp?(timestamp),
    do: Auth.valid_timestamp?(timestamp, Runtime.clock_skew_seconds())

  def verify_signature(secret, domain, method, request_path, query_string, timestamp, signature)
      when is_binary(secret) and is_binary(signature) do
    verify_signature(
      secret,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      "",
      "",
      signature
    )
  end

  def verify_signature(
        secret,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        signature
      )
      when is_binary(secret) and is_binary(signature) do
    verify_signature(
      secret,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      "",
      signature
    )
  end

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
    verify_signature(
      peer,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      "",
      "",
      key_id,
      signature
    )
  end

  def verify_signature(
        secret,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      )
      when is_binary(secret) and is_binary(signature) do
    Auth.verify_secret_signature(
      secret,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id,
      signature
    )
  end

  def verify_signature(
        peer,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        key_id,
        signature
      )
      when is_map(peer) and is_binary(signature) do
    verify_signature(
      peer,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      "",
      key_id,
      signature
    )
  end

  def verify_signature(
        peer,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        key_id,
        signature
      )
      when is_map(peer) and is_binary(signature) do
    Auth.verify_peer_signature(
      peer,
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id,
      key_id,
      signature,
      auth_context()
    )
  end

  def signed_headers(peer, method, request_path, query_string \\ "", body \\ "") do
    Auth.signed_headers(peer, method, request_path, query_string, body, auth_context())
  end

  def request_replay_nonce(
        domain,
        key_id,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      ) do
    Auth.request_replay_nonce(
      domain,
      key_id,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id,
      signature
    )
  end

  def claim_request_nonce(
        domain,
        key_id,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      ) do
    Auth.claim_request_nonce(
      domain,
      key_id,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id,
      signature,
      auth_context()
    )
  end

  def incoming_verification_materials_for_key_id(peer, key_id) do
    Auth.incoming_verification_materials_for_key_id(peer, key_id)
  end

  defp auth_context do
    Contexts.auth(%{
      normalize_optional_string: &normalize_optional_string/1,
      parse_int: &Utils.parse_int/2,
      discover_peer_force: &discover_peer_force/1
    })
  end

  defp discover_peer_force(domain) do
    Discovery.discover_peer(domain, [force: true], discovery_context())
  end

  defp discovery_context do
    Contexts.discovery(%{
      peers: &Peers.peers/0,
      truncate: &Utils.truncate/1
    })
  end

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil
end
