defmodule Elektrine.CustomDomains.DKIMTest do
  use ExUnit.Case, async: true

  alias Elektrine.CustomDomains.DKIM

  describe "generate_key_pair/1" do
    test "generates a valid RSA key pair" do
      assert {:ok, result} = DKIM.generate_key_pair()

      assert is_binary(result.private_key)
      assert is_binary(result.public_key)
      assert result.selector == "elektrine"

      # Private key should be PEM-encoded
      assert String.starts_with?(result.private_key, "-----BEGIN RSA PRIVATE KEY-----")
      assert String.ends_with?(String.trim(result.private_key), "-----END RSA PRIVATE KEY-----")

      # Public key should be base64-encoded DER
      assert {:ok, _} = Base.decode64(result.public_key)
    end

    test "uses custom selector when provided" do
      assert {:ok, result} = DKIM.generate_key_pair("custom-selector")
      assert result.selector == "custom-selector"
    end
  end

  describe "valid_private_key?/1" do
    test "returns true for valid PEM key" do
      {:ok, %{private_key: pem}} = DKIM.generate_key_pair()
      assert DKIM.valid_private_key?(pem)
    end

    test "returns false for invalid data" do
      refute DKIM.valid_private_key?("not a valid key")
      refute DKIM.valid_private_key?("")
    end
  end

  describe "format_dns_record/1" do
    test "formats public key for DNS TXT record" do
      {:ok, %{public_key: public_key}} = DKIM.generate_key_pair()

      record = DKIM.format_dns_record(public_key)

      assert String.starts_with?(record, "v=DKIM1; k=rsa; p=")
      assert String.contains?(record, public_key)
    end
  end

  describe "sign/5" do
    setup do
      {:ok, keys} = DKIM.generate_key_pair()
      {:ok, keys: keys}
    end

    test "signs email headers and body", %{keys: keys} do
      headers = [
        {"from", "test@example.com"},
        {"to", "recipient@example.com"},
        {"subject", "Test Email"},
        {"date", "Mon, 20 Jan 2025 12:00:00 +0000"}
      ]

      body = "Hello, this is a test email."

      assert {:ok, signature} =
               DKIM.sign(headers, body, "example.com", "elektrine", keys.private_key)

      # Signature should be a valid DKIM-Signature header value
      assert String.starts_with?(signature, "v=1")
      assert String.contains?(signature, "a=rsa-sha256")
      assert String.contains?(signature, "d=example.com")
      assert String.contains?(signature, "s=elektrine")
      assert String.contains?(signature, "bh=")
      assert String.contains?(signature, "b=")
    end

    test "includes body hash (bh=)", %{keys: keys} do
      headers = [{"from", "test@example.com"}]
      body = "Test body"

      {:ok, signature} = DKIM.sign(headers, body, "test.com", "sel", keys.private_key)

      assert String.contains?(signature, "bh=")
    end

    test "returns error for invalid private key" do
      headers = [{"from", "test@example.com"}]
      body = "Test body"

      assert {:error, :signing_failed} =
               DKIM.sign(headers, body, "test.com", "sel", "invalid-key")
    end
  end
end
