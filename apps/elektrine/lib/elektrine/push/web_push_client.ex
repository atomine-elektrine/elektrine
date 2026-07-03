defmodule Elektrine.Push.WebPushClient do
  @moduledoc """
  Web Push delivery adapter implementing RFC 8291 (aes128gcm message
  encryption) and RFC 8292 (VAPID) with OTP `:crypto`, no external deps.

  Requires VAPID keys in config:

      config :elektrine, :push,
        web_push_public_key: "<base64url 65-byte uncompressed P-256 point>",
        web_push_private_key: "<base64url 32-byte scalar>",
        web_push_subject: "mailto:admin@example.com"

  Generate a pair with `Elektrine.Push.WebPushClient.generate_vapid_keys/0`.
  An alternative adapter can still be swapped in via
  `config :elektrine, :web_push_client, MyApp.WebPushClient`.
  """

  require Logger

  @curve :prime256v1
  @record_size 4096
  @jwt_ttl_seconds 12 * 60 * 60

  def deliver(subscription, payload, opts \\ []) do
    config = Application.get_env(:elektrine, :push, [])
    public_key = decode_key(config[:web_push_public_key])
    private_key = decode_key(config[:web_push_private_key])

    if is_nil(public_key) or is_nil(private_key) do
      Logger.debug("Web Push VAPID keys not configured; skipping subscription #{subscription.id}")

      {:ok, :not_configured}
    else
      send_push(subscription, payload, {public_key, private_key, vapid_subject(config)}, opts)
    end
  end

  @doc """
  Generates a VAPID keypair, returned as base64url strings suitable for
  WEB_PUSH_PUBLIC_KEY / WEB_PUSH_PRIVATE_KEY.
  """
  def generate_vapid_keys do
    {public, private} = :crypto.generate_key(:ecdh, @curve)

    %{
      public_key: Base.url_encode64(public, padding: false),
      private_key: Base.url_encode64(private, padding: false)
    }
  end

  defp send_push(subscription, payload, vapid, opts) do
    with {:ok, ua_public} <- decode_subscription_key(subscription.p256dh, 65),
         {:ok, auth_secret} <- decode_subscription_key(subscription.auth, 16) do
      body = encrypt(Jason.encode!(payload), ua_public, auth_secret)
      headers = build_headers(subscription.endpoint, vapid, opts)

      :post
      |> Finch.build(subscription.endpoint, headers, body)
      |> Finch.request(Elektrine.Finch, receive_timeout: 15_000)
      |> handle_response(subscription)
    end
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, _subscription)
       when status in 200..299,
       do: {:ok, :delivered}

  defp handle_response({:ok, %Finch.Response{status: status}}, subscription)
       when status in [404, 410] do
    Logger.info("Web Push subscription #{subscription.id} is gone (#{status})")
    {:error, :subscription_gone}
  end

  defp handle_response({:ok, %Finch.Response{status: status, body: body}}, _subscription),
    do: {:error, {:http_error, status, String.slice(to_string(body), 0, 200)}}

  defp handle_response({:error, reason}, _subscription), do: {:error, reason}

  # --- RFC 8291 / RFC 8188 aes128gcm encryption ---

  @doc false
  def encrypt(plaintext, ua_public, auth_secret) do
    {as_public, as_private} = :crypto.generate_key(:ecdh, @curve)
    ecdh_secret = :crypto.compute_key(:ecdh, ua_public, as_private, @curve)
    salt = :crypto.strong_rand_bytes(16)

    prk_key = hmac(auth_secret, ecdh_secret)
    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hkdf_expand(prk_key, key_info, 32)

    prk = hmac(salt, ikm)
    cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    # single record: payload + 0x02 delimiter (last record), no padding
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, true)

    header = salt <> <<@record_size::unsigned-32, byte_size(as_public)::unsigned-8>> <> as_public
    header <> ciphertext <> tag
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hkdf_expand(prk, info, length) do
    prk |> hmac(info <> <<1>>) |> binary_part(0, length)
  end

  # --- RFC 8292 VAPID ---

  defp build_headers(endpoint, {public_key, private_key, subject}, opts) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    audience = "#{scheme}://#{host}#{audience_port(scheme, port)}"
    exp = System.system_time(:second) + @jwt_ttl_seconds

    jwt =
      sign_jwt(
        %{"typ" => "JWT", "alg" => "ES256"},
        %{"aud" => audience, "exp" => exp, "sub" => subject},
        private_key
      )

    [
      {"authorization", "vapid t=#{jwt}, k=#{Base.url_encode64(public_key, padding: false)}"},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", to_string(Keyword.get(opts, :ttl, 86_400))},
      {"urgency", Keyword.get(opts, :urgency, "normal")}
    ]
  end

  defp audience_port("https", 443), do: ""
  defp audience_port("http", 80), do: ""
  defp audience_port(_scheme, port), do: ":#{port}"

  @doc false
  def sign_jwt(header, claims, private_key) do
    signing_input =
      Base.url_encode64(Jason.encode!(header), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    der_signature =
      :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, @curve])

    signing_input <> "." <> Base.url_encode64(der_to_raw(der_signature), padding: false)
  end

  # JOSE ES256 signatures are raw r || s (32 bytes each); :crypto emits DER.
  defp der_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    pad_to_32(:binary.encode_unsigned(r)) <> pad_to_32(:binary.encode_unsigned(s))
  end

  defp pad_to_32(bin) when byte_size(bin) >= 32, do: binary_part(bin, byte_size(bin) - 32, 32)
  defp pad_to_32(bin), do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin

  defp decode_subscription_key(value, expected_size) when is_binary(value) do
    with {:ok, decoded} <- decode_base64_any(value),
         true <- byte_size(decoded) == expected_size do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_subscription_keys}
    end
  end

  defp decode_subscription_key(_value, _size), do: {:error, :invalid_subscription_keys}

  defp decode_key(nil), do: nil
  defp decode_key(""), do: nil

  defp decode_key(value) when is_binary(value) do
    case decode_base64_any(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_base64_any(value) do
    trimmed = String.trim(value)

    with :error <- Base.url_decode64(trimmed, padding: false),
         :error <- Base.url_decode64(trimmed),
         :error <- Base.decode64(trimmed, padding: false) do
      Base.decode64(trimmed)
    end
  end

  defp vapid_subject(config) do
    config[:web_push_subject] || "mailto:admin@#{primary_domain()}"
  end

  defp primary_domain do
    Application.get_env(:elektrine, :primary_domain) ||
      System.get_env("PRIMARY_DOMAIN") ||
      "localhost"
  end
end
