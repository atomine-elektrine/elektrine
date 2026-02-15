defmodule Elektrine.ActivityPub.HTTPSignature do
  @moduledoc """
  Handles HTTP Signatures for ActivityPub federation.
  Implements signing and verification according to the HTTP Signatures spec.
  """

  require Logger

  @doc """
  Verifies an HTTP signature on an incoming request.
  Returns {:ok, actor_uri} if valid, {:error, reason} otherwise.
  """
  def verify(conn, signature_header) do
    # Parse the signature header
    case parse_signature_header(signature_header) do
      {:ok, params} ->
        verify_signature(conn, params)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_signature_header(header) do
    # Parse: Signature keyId="...",headers="...",signature="..."
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
    # Extract the actor URI from the keyId
    actor_uri = extract_actor_uri(key_id)

    # Fetch the actor to get their public key
    case Elektrine.ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, actor} ->
        # Build the signing string
        headers_list = String.split(headers_string, " ")

        case build_signing_string(conn, headers_list) do
          {:ok, signing_string} ->
            # Decode the signature
            case Base.decode64(signature) do
              {:ok, decoded_signature} ->
                # Verify the signature with the public key
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
        # Actor fetch failed (usually deleted accounts) - not an error, just info
        Logger.info("Could not fetch actor for signature verification: #{actor_uri}")
        {:error, :actor_fetch_failed}
    end
  end

  defp extract_actor_uri(key_id) do
    # KeyId format: https://mastodon.social/users/alice#main-key
    # We want: https://mastodon.social/users/alice
    key_id
    |> String.split("#")
    |> List.first()
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
      signing_string =
        results
        |> Enum.map_join("\n", fn {:ok, line} -> line end)

      {:ok, signing_string}
    else
      {:error, :missing_headers, missing_headers}
    end
  end

  defp get_header_value(conn, header_name) do
    case header_name do
      "(request-target)" ->
        # Special pseudo-header - always available
        method = conn.method |> String.downcase()
        path = conn.request_path
        query = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
        {:ok, "#{method} #{path}#{query}"}

      "(created)" ->
        # Optional pseudo-header for created timestamp - can be missing
        {:ok, ""}

      "(expires)" ->
        # Optional pseudo-header for expires timestamp - can be missing
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
      {:ok, public_key} ->
        :public_key.verify(signing_string, :sha256, signature, public_key)

      {:error, _} ->
        false
    end
  end

  defp decode_public_key(pem) do
    try do
      [entry] = :public_key.pem_decode(pem)
      public_key = :public_key.pem_entry_decode(entry)
      {:ok, public_key}
    rescue
      _ -> {:error, :invalid_key}
    end
  end

  @doc """
  Signs an HTTP GET request for authorized fetch mode.
  Returns headers to add to the request.
  """
  def sign_get(url, private_key_pem, key_id) do
    uri = URI.parse(url)
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

    path_with_query =
      if uri.query do
        "#{uri.path}?#{uri.query}"
      else
        uri.path || "/"
      end

    # Build signing string for GET (no digest needed)
    headers_to_sign = ["(request-target)", "host", "date"]

    signing_string_parts = [
      "(request-target): get #{path_with_query}",
      "host: #{uri.host}",
      "date: #{date}"
    ]

    signing_string = Enum.join(signing_string_parts, "\n")

    # Sign the string
    signature = sign_string(signing_string, private_key_pem)

    # Build signature header
    headers_string = Enum.join(headers_to_sign, " ")

    signature_header =
      [
        ~s(keyId="#{key_id}"),
        ~s(algorithm="hs2019"),
        ~s(headers="#{headers_string}"),
        ~s(signature="#{signature}")
      ]
      |> Enum.join(",")

    # Return headers to add
    [
      {"host", uri.host},
      {"date", date},
      {"signature", signature_header}
    ]
  end

  @doc """
  Signs an HTTP POST request for outgoing federation.
  Returns headers to add to the request.
  """
  def sign(url, body, private_key_pem, key_id) do
    uri = URI.parse(url)
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

    # Calculate digest for POST requests with body
    digest =
      if body do
        "SHA-256=#{:crypto.hash(:sha256, body) |> Base.encode64()}"
      else
        nil
      end

    # Build signing string
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

    # Sign the string
    signature = sign_string(signing_string, private_key_pem)

    # Build signature header
    headers_string = Enum.join(headers_to_sign, " ")

    # Use hs2019 algorithm identifier (RSA-SHA256)
    signature_header =
      [
        ~s(keyId="#{key_id}"),
        ~s(algorithm="hs2019"),
        ~s(headers="#{headers_string}"),
        ~s(signature="#{signature}")
      ]
      |> Enum.join(",")

    # Return headers to add (lowercase for Finch)
    base_headers = [
      {"host", uri.host},
      {"date", date},
      {"signature", signature_header}
    ]

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
    try do
      [entry] = :public_key.pem_decode(pem)
      private_key = :public_key.pem_entry_decode(entry)
      {:ok, private_key}
    rescue
      e ->
        Logger.error("Failed to decode private key: #{inspect(e)}")
        {:error, :invalid_key}
    end
  end

  @doc """
  Generates a new RSA key pair for a user.
  Returns {public_key_pem, private_key_pem}.

  Public key is generated in PKCS#8 format for ActivityPub compatibility.
  """
  def generate_key_pair do
    # Generate 2048-bit RSA key
    private_key = :public_key.generate_key({:rsa, 2048, 65537})

    # Encode private key as RSAPrivateKey (standard format)
    private_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
      ])

    # Generate PKCS#8 format public key using openssl
    temp_dir = System.tmp_dir!()
    private_path = Path.join(temp_dir, "temp_private_#{:rand.uniform(999_999)}.pem")
    public_path = Path.join(temp_dir, "temp_public_#{:rand.uniform(999_999)}.pem")

    try do
      File.write!(private_path, private_pem)

      # Use openssl to extract public key in PKCS#8 format
      case System.cmd("openssl", ["rsa", "-in", private_path, "-pubout", "-out", public_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          # Read the generated public key
          public_pem = File.read!(public_path)
          {public_pem, private_pem}

        {error_output, _code} ->
          Logger.error("OpenSSL failed to generate public key: #{error_output}")
          {extract_public_key_basic(private_key), private_pem}
      end
    after
      # Clean up temp files
      File.rm(private_path)
      File.rm(public_path)
    end
  end

  # Fallback: Extract public key in basic RSAPublicKey format
  defp extract_public_key_basic(
         {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other}
       ) do
    rsa_public_key = {:RSAPublicKey, modulus, exponent}

    :public_key.pem_encode([
      :public_key.pem_entry_encode(:RSAPublicKey, rsa_public_key)
    ])
  end
end
