defmodule Elektrine.ActivityPub.HTTPSignature do
  @moduledoc "Handles HTTP Signatures for ActivityPub federation.\nImplements signing and verification according to the HTTP Signatures spec.\n"
  require Logger

  @doc "Verifies an HTTP signature on an incoming request.\nReturns {:ok, actor_uri} if valid, {:error, reason} otherwise.\n"
  def verify(conn, signature_header) do
    case parse_signature_header(signature_header) do
      {:ok, params} -> verify_signature(conn, params)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_signature_header(header) do
    parts =
      Regex.scan(~r/([A-Za-z][A-Za-z0-9_-]*)=(?:"([^"]*)"|([^,\s]+))/, header)
      |> Enum.reduce(%{}, fn
        [_, key, quoted], acc ->
          Map.put(acc, key, quoted)

        [_, key, quoted, unquoted], acc ->
          value =
            case quoted do
              "" -> String.trim(unquoted)
              _ -> quoted
            end

          Map.put(acc, key, value)
      end)

    required_keys = ["keyId", "headers", "signature"]

    if Enum.all?(required_keys, &Map.has_key?(parts, &1)) do
      {:ok, parts}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp verify_signature(
         conn,
         %{
           "keyId" => key_id,
           "headers" => headers_string,
           "signature" => signature
         } = params
       ) do
    actor_uri = extract_actor_uri(key_id)

    case Elektrine.ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, actor} ->
        headers_list = String.split(headers_string, " ", trim: true)

        case build_signing_string(conn, headers_list, %{
               "created" => Map.get(params, "created"),
               "expires" => Map.get(params, "expires")
             }) do
          {:ok, signing_string} ->
            case Base.decode64(signature) do
              {:ok, decoded_signature} ->
                case verify_with_public_key(signing_string, decoded_signature, actor.public_key) do
                  true ->
                    {:ok, actor_uri}

                  false ->
                    Logger.info("Signature verification failed for #{actor_uri}")
                    {:error, :invalid_signature}
                end

              :error ->
                {:error, :invalid_signature}
            end

          {:error, :missing_headers, missing} ->
            Logger.warning(
              "Signature verification failed: missing required headers #{inspect(missing)} from #{actor_uri}"
            )

            {:error, :missing_headers}
        end

      {:error, _reason} ->
        Logger.info("Could not fetch actor for signature verification: #{actor_uri}")
        {:error, :actor_fetch_failed}
    end
  end

  defp extract_actor_uri(key_id) do
    key_id |> String.split("#") |> List.first()
  end

  defp build_signing_string(conn, headers_list, signature_params) do
    results =
      Enum.map(headers_list, fn header_name ->
        case get_header_value(conn, header_name, signature_params) do
          {:ok, value} -> {:ok, "#{header_name}: #{value}"}
          {:error, :missing} -> {:error, header_name}
        end
      end)

    missing_headers =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:error, name} -> name end)

    if Enum.empty?(missing_headers) do
      signing_string = results |> Enum.map_join("\n", fn {:ok, line} -> line end)
      {:ok, signing_string}
    else
      {:error, :missing_headers, missing_headers}
    end
  end

  defp get_header_value(conn, header_name, signature_params) do
    case header_name do
      "(request-target)" ->
        method = conn.method |> String.downcase()
        path = conn.request_path

        query =
          if conn.query_string != "" do
            "?#{conn.query_string}"
          else
            ""
          end

        {:ok, "#{method} #{path}#{query}"}

      "(created)" ->
        signature_param_value(signature_params, "created")

      "(expires)" ->
        signature_param_value(signature_params, "expires")

      _ ->
        case Plug.Conn.get_req_header(conn, header_name) do
          [value | _] -> {:ok, value}
          [] -> {:error, :missing}
        end
    end
  end

  defp signature_param_value(signature_params, key) do
    case Map.get(signature_params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing}
    end
  end

  defp verify_with_public_key(signing_string, signature, public_key_pem) do
    case decode_public_key(public_key_pem) do
      {:ok, public_key} -> :public_key.verify(signing_string, :sha256, signature, public_key)
      {:error, _} -> false
    end
  end

  defp decode_public_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    public_key = :public_key.pem_entry_decode(entry)
    {:ok, public_key}
  rescue
    _ -> {:error, :invalid_key}
  end

  @doc "Signs an HTTP GET request for authorized fetch mode.\nReturns headers to add to the request.\n"
  def sign_get(url, private_key_pem, key_id) do
    uri = URI.parse(url)
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
    host = host_header_value(uri)

    path_with_query =
      if uri.query do
        "#{uri.path || "/"}?#{uri.query}"
      else
        uri.path || "/"
      end

    headers_to_sign = ["(request-target)", "host", "date"]

    signing_string_parts = [
      "(request-target): get #{path_with_query}",
      "host: #{host}",
      "date: #{date}"
    ]

    signing_string = Enum.join(signing_string_parts, "\n")
    signature = sign_string(signing_string, private_key_pem)
    headers_string = Enum.join(headers_to_sign, " ")

    signature_header =
      [
        ~s(keyId="#{key_id}"),
        ~s(algorithm="hs2019"),
        ~s(headers="#{headers_string}"),
        ~s(signature="#{signature}")
      ]
      |> Enum.join(",")

    [{"host", host}, {"date", date}, {"signature", signature_header}]
  end

  @doc "Signs an HTTP POST request for outgoing federation.\nReturns headers to add to the request.\n"
  def sign(url, body, private_key_pem, key_id) do
    uri = URI.parse(url)
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
    host = host_header_value(uri)

    digest =
      if body do
        "SHA-256=#{:crypto.hash(:sha256, body) |> Base.encode64()}"
      else
        nil
      end

    headers_to_sign =
      if digest do
        ["(request-target)", "host", "date", "digest"]
      else
        ["(request-target)", "host", "date"]
      end

    path_with_query =
      if uri.query do
        "#{uri.path || "/"}?#{uri.query}"
      else
        uri.path || "/"
      end

    signing_string_parts = [
      "(request-target): post #{path_with_query}",
      "host: #{host}",
      "date: #{date}"
    ]

    signing_string_parts =
      if digest do
        signing_string_parts ++ ["digest: #{digest}"]
      else
        signing_string_parts
      end

    signing_string = Enum.join(signing_string_parts, "\n")
    signature = sign_string(signing_string, private_key_pem)
    headers_string = Enum.join(headers_to_sign, " ")

    signature_header =
      [
        ~s(keyId="#{key_id}"),
        ~s(algorithm="hs2019"),
        ~s(headers="#{headers_string}"),
        ~s(signature="#{signature}")
      ]
      |> Enum.join(",")

    base_headers = [{"host", host}, {"date", date}, {"signature", signature_header}]

    if digest do
      base_headers ++ [{"digest", digest}]
    else
      base_headers
    end
  end

  defp sign_string(string, private_key_pem) do
    case decode_private_key(private_key_pem) do
      {:ok, private_key} ->
        signature = :public_key.sign(string, :sha256, private_key)
        Base.encode64(signature)

      {:error, _} ->
        raise "Failed to decode private key"
    end
  end

  defp decode_private_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    private_key = :public_key.pem_entry_decode(entry)
    {:ok, private_key}
  rescue
    e ->
      Logger.error("Failed to decode private key: #{inspect(e)}")
      {:error, :invalid_key}
  end

  defp host_header_value(%URI{host: host, port: port, scheme: scheme}) when is_binary(host) do
    if is_nil(port) or default_port?(scheme, port) do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp host_header_value(%URI{host: host}) when is_binary(host), do: host

  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_, _), do: false

  @doc "Generates a new RSA key pair for a user.\nReturns {public_key_pem, private_key_pem}.\n\nPublic key is generated in PKCS#8 format for ActivityPub compatibility.\n"
  def generate_key_pair do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}

    private_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    public_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])

    {public_pem, private_pem}
  end
end
