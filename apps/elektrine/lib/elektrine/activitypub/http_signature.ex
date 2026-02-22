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
      header
      |> String.split(",")
      |> Enum.map(fn part ->
        [key, value] = String.split(part, "=", parts: 2)
        {String.trim(key), String.trim(value, "\"")}
      end)
      |> Enum.into(%{})

    required_keys = ["keyId", "headers", "signature"]

    if Enum.all?(required_keys, &Map.has_key?(parts, &1)) do
      {:ok, parts}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp verify_signature(conn, %{
         "keyId" => key_id,
         "headers" => headers_string,
         "signature" => signature
       }) do
    actor_uri = extract_actor_uri(key_id)

    case Elektrine.ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, actor} ->
        headers_list = String.split(headers_string, " ")

        case build_signing_string(conn, headers_list) do
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

  defp build_signing_string(conn, headers_list) do
    results =
      Enum.map(headers_list, fn header_name ->
        case get_header_value(conn, header_name) do
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

  defp get_header_value(conn, header_name) do
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
        {:ok, ""}

      "(expires)" ->
        {:ok, ""}

      _ ->
        case Plug.Conn.get_req_header(conn, header_name) do
          [value | _] -> {:ok, value}
          [] -> {:error, :missing}
        end
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

    path_with_query =
      if uri.query do
        "#{uri.path}?#{uri.query}"
      else
        uri.path || "/"
      end

    headers_to_sign = ["(request-target)", "host", "date"]

    signing_string_parts = [
      "(request-target): get #{path_with_query}",
      "host: #{uri.host}",
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

    [{"host", uri.host}, {"date", date}, {"signature", signature_header}]
  end

  @doc "Signs an HTTP POST request for outgoing federation.\nReturns headers to add to the request.\n"
  def sign(url, body, private_key_pem, key_id) do
    uri = URI.parse(url)
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

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
        "#{uri.path}?#{uri.query}"
      else
        uri.path || "/"
      end

    signing_string_parts = [
      "(request-target): post #{path_with_query}",
      "host: #{uri.host}",
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

    base_headers = [{"host", uri.host}, {"date", date}, {"signature", signature_header}]

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

  @doc "Generates a new RSA key pair for a user.\nReturns {public_key_pem, private_key_pem}.\n\nPublic key is generated in PKCS#8 format for ActivityPub compatibility.\n"
  def generate_key_pair do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    private_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    temp_dir = System.tmp_dir!()
    private_path = Path.join(temp_dir, "temp_private_#{:rand.uniform(999_999)}.pem")
    public_path = Path.join(temp_dir, "temp_public_#{:rand.uniform(999_999)}.pem")

    try do
      File.write!(private_path, private_pem)

      case System.cmd("openssl", ["rsa", "-in", private_path, "-pubout", "-out", public_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          public_pem = File.read!(public_path)
          {public_pem, private_pem}

        {error_output, _code} ->
          Logger.error("OpenSSL failed to generate public key: #{error_output}")
          {extract_public_key_basic(private_key), private_pem}
      end
    after
      File.rm(private_path)
      File.rm(public_path)
    end
  end

  defp extract_public_key_basic(
         {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other}
       ) do
    rsa_public_key = {:RSAPublicKey, modulus, exponent}
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, rsa_public_key)])
  end
end
