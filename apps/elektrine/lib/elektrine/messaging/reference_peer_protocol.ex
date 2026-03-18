defmodule Elektrine.Messaging.ReferencePeerProtocol do
  @moduledoc false

  @protocol_name "arblarg"
  @protocol_id "arblarg"
  @protocol_version "1.0"
  @protocol_label "arblarg/1.0"
  @signature_algorithm "ed25519"
  @clock_skew_seconds 300

  def protocol_name, do: @protocol_name
  def protocol_id, do: @protocol_id
  def protocol_version, do: @protocol_version
  def protocol_label, do: @protocol_label
  def signature_algorithm, do: @signature_algorithm

  def derive_keypair_from_secret(secret) when is_binary(secret) do
    seed = :crypto.hash(:sha256, secret) |> binary_part(0, 32)
    :crypto.generate_key(:eddsa, :ed25519, seed)
  end

  def canonical_json_payload(value) do
    canonical_json(value)
  end

  def body_digest(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.url_encode64(padding: false)
  end

  def body_digest(_body), do: body_digest("")

  def canonical_request_signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest \\ "",
        request_id \\ ""
      ) do
    [
      String.downcase(to_string(domain || "")),
      String.downcase(to_string(method || "")),
      canonical_path(request_path),
      canonical_query_string(query_string),
      to_string(timestamp || "") |> String.trim(),
      canonical_content_digest(content_digest),
      to_string(request_id || "") |> String.trim()
    ]
    |> Enum.join("\n")
  end

  def sign_payload(payload, private_key_material) when is_binary(payload) do
    case normalize_private_key(private_key_material) do
      {:ok, private_key} ->
        :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
        |> Base.url_encode64(padding: false)

      _ ->
        ""
    end
  end

  def verify_payload_signature(payload, public_key_material, signature)
      when is_binary(payload) and is_binary(signature) do
    with {:ok, public_key} <- normalize_public_key(public_key_material),
         {:ok, raw_signature} <- Base.url_decode64(String.trim(signature), padding: false) do
      :crypto.verify(:eddsa, :none, payload, raw_signature, [public_key, :ed25519])
    else
      _ -> false
    end
  end

  def verify_payload_signature(_payload, _public_key_material, _signature), do: false

  def sign_event_envelope(envelope, key_id, private_key_material) when is_map(envelope) do
    signature_value =
      envelope
      |> canonical_event_signature_payload()
      |> sign_payload(private_key_material)

    Map.put(envelope, "signature", %{
      "algorithm" => @signature_algorithm,
      "key_id" => to_string(key_id || ""),
      "value" => signature_value
    })
  end

  def validate_event_envelope(envelope) when is_map(envelope) do
    idempotency_key = envelope["idempotency_key"] || envelope["event_id"]
    signature = envelope["signature"] || %{}

    cond do
      envelope["protocol"] != @protocol_name ->
        {:error, :unsupported_protocol}

      envelope["protocol_id"] != @protocol_id ->
        {:error, :unsupported_protocol}

      envelope["protocol_version"] != @protocol_version ->
        {:error, :unsupported_version}

      !non_empty_binary?(envelope["event_id"]) ->
        {:error, :invalid_payload}

      !non_empty_binary?(envelope["event_type"]) ->
        {:error, :unsupported_event_type}

      !non_empty_binary?(envelope["origin_domain"]) ->
        {:error, :invalid_payload}

      !non_empty_binary?(envelope["stream_id"]) ->
        {:error, :invalid_payload}

      !is_integer(envelope["sequence"]) or envelope["sequence"] < 1 ->
        {:error, :invalid_payload}

      !non_empty_binary?(idempotency_key) ->
        {:error, :invalid_payload}

      !valid_iso8601?(envelope["sent_at"]) ->
        {:error, :invalid_payload}

      !is_map(envelope["payload"]) ->
        {:error, :invalid_payload}

      !valid_signature_map?(signature) ->
        {:error, :invalid_signature}

      true ->
        validate_event_payload(envelope["event_type"], envelope["payload"])
    end
  end

  def validate_event_envelope(_envelope), do: {:error, :invalid_payload}

  def verify_event_envelope_signature(envelope, key_lookup_fun)
      when is_map(envelope) and is_function(key_lookup_fun, 1) do
    signature = envelope["signature"] || %{}
    key_id = signature["key_id"]
    algorithm = signature["algorithm"]
    value = signature["value"]

    if is_binary(key_id) and is_binary(value) and algorithm == @signature_algorithm do
      envelope_without_signature = Map.delete(envelope, "signature")
      verification_materials = key_lookup_fun.(key_id) |> List.wrap()

      Enum.any?(verification_materials, fn public_key_material ->
        verify_payload_signature(
          canonical_event_signature_payload(envelope_without_signature),
          public_key_material,
          value
        )
      end)
    else
      false
    end
  end

  def verify_event_envelope_signature(_envelope, _key_lookup_fun), do: false

  def signed_headers(domain, key_id, private_key_material, method, path, query_string, body) do
    timestamp = Integer.to_string(System.system_time(:second))
    request_id = Ecto.UUID.generate()
    content_digest = body_digest(body)

    signature =
      canonical_request_signature_payload(
        domain,
        method,
        path,
        query_string,
        timestamp,
        content_digest,
        request_id
      )
      |> sign_payload(private_key_material)

    [
      {"x-arblarg-domain", domain},
      {"x-arblarg-key-id", key_id},
      {"x-arblarg-timestamp", timestamp},
      {"x-arblarg-content-digest", content_digest},
      {"x-arblarg-request-id", request_id},
      {"x-arblarg-signature-algorithm", @signature_algorithm},
      {"x-arblarg-signature", signature}
    ]
  end

  def verify_signed_headers(headers, method, path, query_string, body, key_lookup_fun)
      when is_list(headers) and is_function(key_lookup_fun, 1) do
    normalized =
      Enum.reduce(headers, %{}, fn {key, value}, acc ->
        Map.put(acc, String.downcase(to_string(key)), to_string(value))
      end)

    domain = Map.get(normalized, "x-arblarg-domain")
    key_id = Map.get(normalized, "x-arblarg-key-id")
    timestamp = Map.get(normalized, "x-arblarg-timestamp")
    content_digest = Map.get(normalized, "x-arblarg-content-digest")
    request_id = Map.get(normalized, "x-arblarg-request-id")
    algorithm = Map.get(normalized, "x-arblarg-signature-algorithm")
    signature = Map.get(normalized, "x-arblarg-signature")

    cond do
      !non_empty_binary?(domain) ->
        {:error, :missing_domain}

      !non_empty_binary?(key_id) ->
        {:error, :missing_key_id}

      !valid_timestamp?(timestamp) ->
        {:error, :invalid_timestamp}

      canonical_content_digest(content_digest) != body_digest(body) ->
        {:error, :invalid_content_digest}

      !non_empty_binary?(request_id) ->
        {:error, :missing_request_id}

      algorithm != @signature_algorithm ->
        {:error, :invalid_signature_algorithm}

      !non_empty_binary?(signature) ->
        {:error, :missing_signature}

      true ->
        payload =
          canonical_request_signature_payload(
            domain,
            method,
            path,
            query_string,
            timestamp,
            content_digest,
            request_id
          )

        materials = key_lookup_fun.(key_id) |> List.wrap()

        if Enum.any?(materials, &verify_payload_signature(payload, &1, signature)) do
          {:ok, domain}
        else
          {:error, :invalid_signature}
        end
    end
  end

  def verify_signed_headers(_headers, _method, _path, _query_string, _body, _key_lookup_fun) do
    {:error, :invalid_signature}
  end

  def valid_timestamp?(timestamp, skew_seconds \\ @clock_skew_seconds)

  def valid_timestamp?(timestamp, skew_seconds) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {ts, ""} when is_integer(skew_seconds) and skew_seconds >= 0 ->
        abs(System.system_time(:second) - ts) <= skew_seconds

      _ ->
        false
    end
  end

  def valid_timestamp?(_timestamp, _skew_seconds), do: false

  defp validate_event_payload("message.create", payload), do: validate_message_payload(payload)
  defp validate_event_payload("message.update", payload), do: validate_message_payload(payload)
  defp validate_event_payload("message.delete", payload), do: validate_delete_payload(payload)
  defp validate_event_payload(_event_type, payload) when is_map(payload), do: :ok
  defp validate_event_payload(_event_type, _payload), do: {:error, :invalid_event_payload}

  defp validate_message_payload(payload) when is_map(payload) do
    message = payload["message"]

    cond do
      !is_map(message) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(message["id"]) ->
        {:error, :invalid_event_payload}

      !is_binary(message["content"] || "") ->
        {:error, :invalid_event_payload}

      !is_map(message["sender"]) ->
        {:error, :invalid_event_payload}

      !valid_attachment_list?(message["attachments"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_message_payload(_payload), do: {:error, :invalid_event_payload}

  defp validate_delete_payload(payload) when is_map(payload) do
    if non_empty_binary?(payload["message_id"]), do: :ok, else: {:error, :invalid_event_payload}
  end

  defp validate_delete_payload(_payload), do: {:error, :invalid_event_payload}

  defp valid_attachment_list?(nil), do: true

  defp valid_attachment_list?(attachments) when is_list(attachments) do
    Enum.all?(attachments, &valid_attachment?/1)
  end

  defp valid_attachment_list?(_attachments), do: false

  defp valid_attachment?(attachment) when is_map(attachment) do
    authorization = attachment["authorization"]
    retention = attachment["retention"]

    non_empty_binary?(attachment["id"]) and
      non_empty_binary?(attachment["url"]) and
      non_empty_binary?(attachment["mime_type"]) and
      authorization in ["public", "signed", "origin-authenticated"] and
      retention in ["origin", "rehosted", "expiring"]
  end

  defp valid_attachment?(_attachment), do: false

  defp valid_signature_map?(signature) when is_map(signature) do
    non_empty_binary?(signature["key_id"]) and
      non_empty_binary?(signature["value"]) and
      signature["algorithm"] == @signature_algorithm
  end

  defp valid_signature_map?(_signature), do: false

  defp canonical_event_signature_payload(envelope) do
    payload = envelope["payload"] || %{}
    idempotency_key = envelope["idempotency_key"] || envelope["event_id"]

    [
      @protocol_id,
      to_string(envelope["protocol_version"] || ""),
      to_string(envelope["event_type"] || ""),
      to_string(envelope["event_id"] || ""),
      to_string(envelope["origin_domain"] || ""),
      to_string(envelope["stream_id"] || ""),
      to_string(parse_int(envelope["sequence"], 0)),
      to_string(envelope["sent_at"] || ""),
      to_string(idempotency_key || ""),
      canonical_json(payload)
    ]
    |> Enum.join("\n")
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), val} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, val} ->
      Jason.encode!(key) <> ":" <> canonical_json(val)
    end)
    |> then(fn body -> "{" <> body <> "}" end)
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &canonical_json/1)
    |> then(fn body -> "[" <> body <> "]" end)
  end

  defp canonical_json(value), do: Jason.encode!(value)

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

  defp canonical_content_digest(content_digest),
    do: canonical_content_digest(to_string(content_digest))

  defp normalize_private_key(key) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, key}

  defp normalize_private_key(%{private_key: key}), do: normalize_private_key(key)
  defp normalize_private_key(%{secret: secret}), do: normalize_private_key(secret)

  defp normalize_private_key(key) when is_binary(key) do
    case decode_32_byte_key(String.trim(key)) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {_public_key, private_key} = derive_keypair_from_secret(key)
        {:ok, private_key}
    end
  end

  defp normalize_private_key(_key), do: {:error, :invalid_private_key}

  defp normalize_public_key(key) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, key}

  defp normalize_public_key(%{public_key: key}), do: normalize_public_key(key)
  defp normalize_public_key(%{secret: secret}), do: normalize_public_key(secret)

  defp normalize_public_key(key) when is_binary(key) do
    case decode_32_byte_key(String.trim(key)) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {public_key, _private_key} = derive_keypair_from_secret(key)
        {:ok, public_key}
    end
  end

  defp normalize_public_key(_key), do: {:error, :invalid_public_key}

  defp decode_32_byte_key(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> decode_32_byte_key_standard(encoded)
    end
  end

  defp decode_32_byte_key_standard(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> :error
    end
  end

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false

  defp valid_iso8601?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> true
      _ -> false
    end
  end

  defp valid_iso8601?(_value), do: false
end
