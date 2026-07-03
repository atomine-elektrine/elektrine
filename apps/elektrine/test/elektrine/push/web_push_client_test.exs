defmodule Elektrine.Push.WebPushClientTest do
  use ExUnit.Case, async: true

  alias Elektrine.Push.WebPushClient

  @curve :prime256v1

  describe "encrypt/3 (RFC 8291 aes128gcm)" do
    test "browser-side decryption round-trips the payload" do
      # Simulate the browser: its ECDH keypair + 16-byte auth secret,
      # then decrypt the record exactly as a User Agent would.
      {ua_public, ua_private} = :crypto.generate_key(:ecdh, @curve)
      auth_secret = :crypto.strong_rand_bytes(16)
      plaintext = ~s({"title":"Hello","body":"World"})

      record = WebPushClient.encrypt(plaintext, ua_public, auth_secret)

      <<salt::binary-16, _rs::unsigned-32, key_len::unsigned-8, rest::binary>> = record
      <<as_public::binary-size(key_len), body::binary>> = rest

      ecdh_secret = :crypto.compute_key(:ecdh, as_public, ua_private, @curve)
      prk_key = :crypto.mac(:hmac, :sha256, auth_secret, ecdh_secret)
      key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
      ikm = hkdf_expand(prk_key, key_info, 32)
      prk = :crypto.mac(:hmac, :sha256, salt, ikm)
      cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
      nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

      tag_size = 16
      data_size = byte_size(body) - tag_size
      <<ciphertext::binary-size(data_size), tag::binary-size(tag_size)>> = body

      decrypted =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

      assert decrypted == plaintext <> <<2>>
    end
  end

  describe "sign_jwt/3 (RFC 8292 VAPID)" do
    test "produces a valid ES256 JWT verifiable with the public key" do
      {public, private} = :crypto.generate_key(:ecdh, @curve)

      jwt =
        WebPushClient.sign_jwt(
          %{"typ" => "JWT", "alg" => "ES256"},
          %{"aud" => "https://push.example.net", "exp" => 1_800_000_000, "sub" => "mailto:a@b.c"},
          private
        )

      [header_b64, claims_b64, signature_b64] = String.split(jwt, ".")

      assert %{"alg" => "ES256"} =
               header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert %{"aud" => "https://push.example.net"} =
               claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      raw_signature = Base.url_decode64!(signature_b64, padding: false)
      assert byte_size(raw_signature) == 64
      <<r::unsigned-256, s::unsigned-256>> = raw_signature

      der_signature =
        :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

      assert :crypto.verify(
               :ecdsa,
               :sha256,
               header_b64 <> "." <> claims_b64,
               der_signature,
               [public, @curve]
             )
    end
  end

  describe "generate_vapid_keys/0" do
    test "returns base64url keys of the expected sizes" do
      %{public_key: pub, private_key: priv} = WebPushClient.generate_vapid_keys()

      assert byte_size(Base.url_decode64!(pub, padding: false)) == 65
      assert byte_size(Base.url_decode64!(priv, padding: false)) in 1..32
    end
  end

  defp hkdf_expand(prk, info, length) do
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)
  end
end
