defmodule Elektrine.CustomDomains.DKIM do
  @moduledoc """
  DKIM (DomainKeys Identified Mail) key management and signing.

  Handles:
  - RSA key pair generation for custom domains
  - DKIM signature generation for outgoing emails
  - Public key formatting for DNS TXT records
  """

  require Logger

  @default_selector "elektrine"
  @key_size 2048

  @doc """
  Generates a new RSA key pair for DKIM signing.

  Returns:
      {:ok, %{private_key: pem_string, public_key: base64_string, selector: string}}

  The private_key is a PEM-encoded RSA private key.
  The public_key is a base64-encoded public key suitable for DNS TXT records.
  """
  def generate_key_pair(selector \\ @default_selector) do
    try do
      # Generate RSA key pair
      private_key = :public_key.generate_key({:rsa, @key_size, 65537})

      # Extract public key
      public_key = extract_public_key(private_key)

      # Encode private key as PEM
      private_pem = encode_private_key_pem(private_key)

      # Encode public key as base64 for DNS record
      public_base64 = encode_public_key_base64(public_key)

      {:ok,
       %{
         private_key: private_pem,
         public_key: public_base64,
         selector: selector
       }}
    rescue
      error ->
        Logger.error("Failed to generate DKIM key pair: #{inspect(error)}")
        {:error, :key_generation_failed}
    end
  end

  @doc """
  Signs an email with DKIM.

  Takes the email headers and body, along with the signing parameters,
  and returns the DKIM-Signature header value.

  ## Parameters

  - `headers` - List of {name, value} tuples for email headers
  - `body` - The email body as a string
  - `domain` - The signing domain (e.g., "example.com")
  - `selector` - The DKIM selector (e.g., "elektrine")
  - `private_key_pem` - The PEM-encoded private key

  ## Returns

  The complete DKIM-Signature header value to be prepended to the email.
  """
  def sign(headers, body, domain, selector, private_key_pem) do
    with {:ok, private_key} <- decode_private_key_pem(private_key_pem) do
      # Canonicalize body (using relaxed/relaxed)
      canonical_body = canonicalize_body(body)

      # Compute body hash (bh=)
      body_hash = :crypto.hash(:sha256, canonical_body) |> Base.encode64()

      # Build the DKIM-Signature header (without b= value)
      timestamp = System.system_time(:second)

      dkim_header_parts = [
        "v=1",
        "a=rsa-sha256",
        "c=relaxed/relaxed",
        "d=#{domain}",
        "s=#{selector}",
        "t=#{timestamp}",
        "bh=#{body_hash}",
        "h=#{signed_headers(headers)}",
        "b="
      ]

      dkim_header_value = Enum.join(dkim_header_parts, "; ")

      # Add DKIM-Signature to headers for signing
      headers_to_sign =
        headers
        |> filter_signed_headers()
        |> Kernel.++([{"dkim-signature", dkim_header_value}])

      # Canonicalize headers for signing
      headers_data = canonicalize_headers_for_signing(headers_to_sign)

      # Sign the header data
      signature = :public_key.sign(headers_data, :sha256, private_key)
      signature_base64 = Base.encode64(signature)

      # Return complete DKIM-Signature header
      {:ok, dkim_header_value <> signature_base64}
    else
      {:error, reason} ->
        Logger.warning("Failed to sign email with DKIM: #{inspect(reason)}")
        {:error, :signing_failed}
    end
  end

  @doc """
  Formats the DKIM public key for DNS TXT record.

  Returns the full TXT record value: `v=DKIM1; k=rsa; p=<base64_key>`
  """
  def format_dns_record(public_key_base64) do
    "v=DKIM1; k=rsa; p=#{public_key_base64}"
  end

  @doc """
  Validates that a private key PEM can be parsed.
  """
  def valid_private_key?(private_key_pem) do
    match?({:ok, _}, decode_private_key_pem(private_key_pem))
  end

  # Private functions

  defp extract_public_key(private_key) do
    # RSAPrivateKey record has public exponent at position 4 and modulus at position 3
    # But we can use :public_key functions to extract it properly
    {:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _} = private_key
    {:RSAPublicKey, modulus, public_exponent}
  end

  defp encode_private_key_pem(private_key) do
    der = :public_key.der_encode(:RSAPrivateKey, private_key)
    pem_entry = {:RSAPrivateKey, der, :not_encrypted}
    :public_key.pem_encode([pem_entry])
  end

  defp encode_public_key_base64(public_key) do
    der = :public_key.der_encode(:RSAPublicKey, public_key)
    Base.encode64(der)
  end

  defp decode_private_key_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [pem_entry | _] ->
        {:ok, :public_key.pem_entry_decode(pem_entry)}

      [] ->
        {:error, :invalid_pem}
    end
  rescue
    _ -> {:error, :invalid_pem}
  end

  # Headers to include in DKIM signature (in order of preference)
  @signed_header_names ~w(from to subject date message-id mime-version content-type)

  defp signed_headers(headers) do
    headers
    |> filter_signed_headers()
    |> Enum.map_join(":", fn {name, _} -> String.downcase(name) end)
  end

  defp filter_signed_headers(headers) do
    Enum.filter(headers, fn {name, _} ->
      String.downcase(name) in @signed_header_names
    end)
  end

  # Relaxed canonicalization for headers
  defp canonicalize_headers_for_signing(headers) do
    headers
    |> Enum.map(fn {name, value} ->
      name_lower = String.downcase(name)
      value_clean = value |> String.trim() |> String.replace(~r/\s+/, " ")
      "#{name_lower}:#{value_clean}"
    end)
    |> Enum.map_join("\r\n", & &1)
  end

  # Relaxed canonicalization for body
  defp canonicalize_body(body) do
    body
    # Replace sequences of whitespace with single space
    |> String.replace(~r/[ \t]+/, " ")
    # Remove trailing whitespace from lines
    |> String.replace(~r/ +\r?\n/, "\r\n")
    # Ensure CRLF line endings
    |> String.replace(~r/(?<!\r)\n/, "\r\n")
    # Remove trailing empty lines
    |> String.replace(~r/(\r\n)+$/, "\r\n")
    # Ensure body ends with CRLF
    |> ensure_crlf_ending()
  end

  defp ensure_crlf_ending(body) do
    if String.ends_with?(body, "\r\n") do
      body
    else
      body <> "\r\n"
    end
  end
end
