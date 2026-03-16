defmodule Elektrine.ActivityPub.HTTPSignatureTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.HTTPSignature
  alias Elektrine.ActivityPub.SigningKey

  test "sign_get includes non-default ports in the host header and signature" do
    {public_key_pem, private_key_pem} = SigningKey.generate_key_pair()

    headers =
      HTTPSignature.sign_get(
        "https://example.com:8443/actors/alice?page=1",
        private_key_pem,
        "https://local.example/users/alice#main-key"
      )

    assert {"host", "example.com:8443"} in headers

    date = header_value(headers, "date")

    signing_string =
      """
      (request-target): get /actors/alice?page=1
      host: example.com:8443
      date: #{date}
      """
      |> String.trim_trailing()

    assert verify_signature(signing_string, signature_value(headers), public_key_pem)
  end

  test "sign includes non-default ports in the host header and signature" do
    {public_key_pem, private_key_pem} = SigningKey.generate_key_pair()
    body = ~s({"type":"Follow"})

    headers =
      HTTPSignature.sign(
        "https://example.com:8443/inbox?shared=true",
        body,
        private_key_pem,
        "https://local.example/users/alice#main-key"
      )

    digest = "SHA-256=#{:crypto.hash(:sha256, body) |> Base.encode64()}"

    assert {"host", "example.com:8443"} in headers
    assert {"digest", digest} in headers

    date = header_value(headers, "date")

    signing_string =
      """
      (request-target): post /inbox?shared=true
      host: example.com:8443
      date: #{date}
      digest: #{digest}
      """
      |> String.trim_trailing()

    assert verify_signature(signing_string, signature_value(headers), public_key_pem)
  end

  defp signature_value(headers) do
    Regex.run(~r/signature="([^"]+)"/, header_value(headers, "signature"),
      capture: :all_but_first
    )
    |> List.first()
  end

  defp header_value(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp verify_signature(signing_string, signature, public_key_pem) do
    {:ok, decoded_signature} = Base.decode64(signature)
    [entry] = :public_key.pem_decode(public_key_pem)
    public_key = :public_key.pem_entry_decode(entry)

    :public_key.verify(signing_string, :sha256, decoded_signature, public_key)
  end
end
