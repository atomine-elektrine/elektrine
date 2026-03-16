defmodule Elektrine.Messaging.Federation.Auth do
  @moduledoc false

  alias Elektrine.Messaging.{ArblargSDK, FederationRequestReplay}
  alias Elektrine.Repo

  def signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest \\ "",
        request_id \\ ""
      ) do
    ArblargSDK.canonical_request_signature_payload(
      domain,
      method,
      request_path,
      query_string,
      timestamp,
      content_digest,
      request_id
    )
  end

  def body_digest(body) when is_binary(body), do: ArblargSDK.body_digest(body)
  def body_digest(_body), do: body_digest("")

  def sign_payload(payload, signing_material) when is_binary(payload) do
    ArblargSDK.sign_payload(payload, signing_material)
  end

  def valid_timestamp?(timestamp, clock_skew_seconds) when is_binary(timestamp) do
    ArblargSDK.valid_timestamp?(timestamp, clock_skew_seconds)
  end

  def verify_secret_signature(
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
    payload =
      signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id
      )

    case ArblargSDK.verification_public_key(secret) do
      {:ok, public_key} -> ArblargSDK.verify_payload_signature(payload, public_key, signature)
      _ -> false
    end
  end

  def verify_peer_signature(
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
        context
      )
      when is_map(peer) and is_binary(signature) and is_map(context) do
    if verify_signature_with_peer(
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
       ) do
      true
    else
      maybe_refresh_discovered_peer_signature(
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
        context
      )
    end
  end

  def signed_headers(peer, method, request_path, query_string, body, context)
      when is_map(peer) and is_binary(method) and is_binary(request_path) and is_map(context) do
    timestamp = Integer.to_string(System.system_time(:second))
    domain = call(context, :local_domain, [])
    request_id = Ecto.UUID.generate()
    {key_id, signing_material} = outbound_signing_material(peer, context)
    content_digest = body_digest(body)

    signature =
      signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id
      )
      |> sign_payload(signing_material)

    [
      {"content-type", "application/json"},
      {"x-arblarg-domain", domain},
      {"x-arblarg-key-id", key_id},
      {"x-arblarg-timestamp", timestamp},
      {"x-arblarg-content-digest", content_digest},
      {"x-arblarg-request-id", request_id},
      {"x-arblarg-signature-algorithm", ArblargSDK.signature_algorithm()},
      {"x-arblarg-signature", signature}
    ]
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
    base =
      [
        to_string(domain || "") |> String.downcase(),
        to_string(key_id || ""),
        to_string(method || "") |> String.upcase(),
        canonical_path(request_path),
        canonical_query_string(query_string),
        to_string(timestamp || "") |> String.trim(),
        canonical_content_digest(content_digest),
        to_string(request_id || "") |> String.trim(),
        to_string(signature || "") |> String.trim()
      ]
      |> Enum.join("\n")

    :crypto.hash(:sha256, base) |> Base.url_encode64(padding: false)
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
        signature,
        context
      )
      when is_map(context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, call(context, :replay_nonce_ttl_seconds, []), :second)

    nonce =
      request_replay_nonce(
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

    inserted_at = DateTime.to_naive(now)

    attrs = [
      %{
        nonce: nonce,
        origin_domain: to_string(domain || ""),
        key_id: call(context, :normalize_optional_string, [key_id]),
        http_method: to_string(method || "") |> String.upcase(),
        request_path: canonical_path(request_path),
        timestamp: call(context, :parse_int, [timestamp, 0]),
        seen_at: now,
        expires_at: expires_at,
        inserted_at: inserted_at
      }
    ]

    {count, _} = Repo.insert_all(FederationRequestReplay, attrs, on_conflict: :nothing)

    if count == 1, do: :ok, else: {:error, :replayed_request}
  end

  def incoming_verification_materials_for_key_id(peer, key_id) when is_map(peer) do
    case normalize_optional_string(key_id) do
      nil ->
        peer.keys
        |> Enum.map(&key_verification_material/1)
        |> Enum.reject(&is_nil/1)

      requested_key_id ->
        peer.keys
        |> Enum.filter(&(key_id_for(&1) == requested_key_id))
        |> Enum.map(&key_verification_material/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  def incoming_verification_materials_for_key_id(_peer, _key_id), do: []

  def outbound_signing_material(peer, context) when is_map(peer) and is_map(context) do
    active_key_id = peer.active_outbound_key_id

    case Enum.find(peer.keys, fn key -> key.id == active_key_id and is_binary(key.private_key) end) do
      %{id: id, private_key: private_key} ->
        {id, private_key}

      _ ->
        peer.keys
        |> Enum.find(&is_binary(&1.private_key))
        |> case do
          %{id: id, private_key: private_key} -> {id, private_key}
          _ -> call(context, :local_event_signing_material, [])
        end
    end
  end

  def outbound_signing_material(_peer, context), do: call(context, :local_event_signing_material, [])

  defp verify_signature_with_peer(
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
       ) do
    peer
    |> incoming_verification_materials_for_key_id(key_id)
    |> Enum.any?(fn public_key_material ->
      verify_secret_signature(
        public_key_material,
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest,
        request_id,
        signature
      )
    end)
  end

  defp maybe_refresh_discovered_peer_signature(
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
         context
       ) do
    if discovered_peer?(peer) do
      case call(context, :discover_peer_force, [peer.domain]) do
        {:ok, %{allow_incoming: true} = refreshed_peer} ->
          verify_signature_with_peer(
            refreshed_peer,
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

        _ ->
          false
      end
    else
      false
    end
  end

  defp discovered_peer?(peer) when is_map(peer) do
    Map.get(peer, :discovery_source) == :dynamic or Map.get(peer, "discovery_source") == :dynamic
  end

  defp discovered_peer?(_peer), do: false

  defp key_verification_material(key) when is_map(key) do
    Map.get(key, :public_key) || Map.get(key, "public_key") || Map.get(key, :secret) ||
      Map.get(key, "secret")
  end

  defp key_verification_material(_key), do: nil

  defp key_id_for(key) when is_map(key) do
    Map.get(key, :id) || Map.get(key, "id")
  end

  defp key_id_for(_key), do: nil

  defp canonical_path(nil), do: "/"

  defp canonical_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> "/"
      String.starts_with?(trimmed, "/") -> trimmed
      true -> "/" <> trimmed
    end
  end

  defp canonical_path(path), do: canonical_path(to_string(path))

  defp canonical_query_string(nil), do: ""
  defp canonical_query_string(query) when is_binary(query), do: String.trim(query)
  defp canonical_query_string(query), do: to_string(query)

  defp canonical_content_digest(nil), do: body_digest("")

  defp canonical_content_digest(content_digest) when is_binary(content_digest) do
    case String.trim(content_digest) do
      "" -> body_digest("")
      value -> value
    end
  end

  defp canonical_content_digest(content_digest), do: canonical_content_digest(to_string(content_digest))

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
