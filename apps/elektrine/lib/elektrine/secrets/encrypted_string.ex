defmodule Elektrine.Secrets.EncryptedString do
  @moduledoc false

  @behaviour Ecto.Type

  @prefix "enc:v1:"
  @aad "ElektrineSecretStringV1"

  def type, do: :string

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case decrypt(value) do
      {:ok, decrypted} -> {:ok, decrypted}
      :error -> {:ok, value}
    end
  end

  def load(_value), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_binary(value) do
    case encrypt(value) do
      {:ok, encrypted} -> {:ok, encrypted}
      :error -> :error
    end
  end

  def dump(_value), do: :error

  def equal?(left, right), do: left == right

  def embed_as(_format), do: :self

  def encrypted?(value) when is_binary(value), do: String.starts_with?(value, @prefix)
  def encrypted?(_value), do: false

  def encrypt(value) when is_binary(value) do
    with {:ok, key} <- key() do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)

      payload = Base.url_encode64(iv <> tag <> ciphertext, padding: false)
      {:ok, @prefix <> payload}
    end
  rescue
    _ -> :error
  end

  def encrypt(_value), do: :error

  def decrypt(value) when is_binary(value) do
    with true <- encrypted?(value),
         payload <- String.replace_prefix(value, @prefix, ""),
         {:ok, binary} <- Base.url_decode64(payload, padding: false),
         true <- byte_size(binary) > 28,
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- binary,
         {:ok, key} <- key(),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def decrypt(_value), do: :error

  defp key do
    master_secret = Application.get_env(:elektrine, :encryption_master_secret)
    key_salt = Application.get_env(:elektrine, :encryption_key_salt)

    if present?(master_secret) and present?(key_salt) do
      {:ok, :crypto.pbkdf2_hmac(:sha256, master_secret, key_salt <> "secret_fields", 100_000, 32)}
    else
      :error
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
