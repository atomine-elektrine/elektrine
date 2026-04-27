defmodule Elektrine.RuntimeSecrets do
  @moduledoc false

  @type env_map :: %{optional(String.t()) => String.t()}

  def master_secret(env \\ System.get_env()) do
    env_value(env, "ELEKTRINE_MASTER_SECRET")
  end

  def secret_key_base(env \\ System.get_env()),
    do: env_value(env, "SECRET_KEY_BASE") || derive(env, "secret_key_base", 48)

  def session_signing_salt(env \\ System.get_env()),
    do: env_value(env, "SESSION_SIGNING_SALT") || derive(env, "session_signing_salt", 24)

  def session_encryption_salt(env \\ System.get_env()),
    do: env_value(env, "SESSION_ENCRYPTION_SALT") || derive(env, "session_encryption_salt", 24)

  def encryption_master_secret(env \\ System.get_env()),
    do: env_value(env, "ENCRYPTION_MASTER_SECRET") || derive(env, "encryption_master_secret", 48)

  def encryption_key_salt(env \\ System.get_env()),
    do: env_value(env, "ENCRYPTION_KEY_SALT") || derive(env, "encryption_key_salt", 24)

  def encryption_search_salt(env \\ System.get_env()),
    do: env_value(env, "ENCRYPTION_SEARCH_SALT") || derive(env, "encryption_search_salt", 24)

  def internal_api_key(env \\ System.get_env()),
    do: env_value(env, "INTERNAL_API_KEY") || derive(env, "internal_api_key", 32)

  def haraka_internal_signing_secret(env \\ System.get_env()),
    do:
      env_value(env, "HARAKA_INTERNAL_SIGNING_SECRET") ||
        derive(env, "haraka_internal_signing_secret", 32)

  def email_receiver_webhook_secret(env \\ System.get_env()),
    do:
      env_value(env, "EMAIL_RECEIVER_WEBHOOK_SECRET") ||
        derive(env, "email_receiver_webhook_secret", 32)

  def turn_shared_secret(env \\ System.get_env()),
    do: env_value(env, "TURN_SHARED_SECRET")

  def derive(env, label, bytes) when is_map(env) and is_binary(label) and bytes > 0 do
    case master_secret(env) do
      nil ->
        nil

      secret ->
        derive_bytes(secret, "elektrine:" <> label, bytes) |> Base.url_encode64(padding: false)
    end
  end

  def env_value(env, key) when is_map(env) and is_binary(key) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp derive_bytes(secret, info, bytes), do: derive_blocks(secret, info, bytes, 1, <<>>)

  defp derive_blocks(_secret, _info, bytes, _counter, acc) when byte_size(acc) >= bytes,
    do: binary_part(acc, 0, bytes)

  defp derive_blocks(secret, info, bytes, counter, acc) do
    block = :crypto.mac(:hmac, :sha256, secret, <<info::binary, ?:, counter::32>>)
    derive_blocks(secret, info, bytes, counter + 1, acc <> block)
  end
end
