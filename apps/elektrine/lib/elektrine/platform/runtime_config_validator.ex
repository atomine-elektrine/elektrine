defmodule Elektrine.Platform.RuntimeConfigValidator do
  @moduledoc false

  alias Elektrine.Platform.Modules

  @haraka_outbound_keys [
    "HARAKA_HTTP_API_KEY",
    "HARAKA_OUTBOUND_API_KEY",
    "HARAKA_API_KEY",
    "INTERNAL_API_KEY"
  ]
  @haraka_inbound_keys [
    "PHOENIX_API_KEY",
    "HARAKA_INBOUND_API_KEY",
    "HARAKA_API_KEY",
    "INTERNAL_API_KEY"
  ]
  @derived_secret_roots ["ELEKTRINE_MASTER_SECRET"]
  @known_placeholder_values [
    "change-me",
    "replace-me",
    "replace-with-long-random-secret",
    "example-secret-access-key",
    "magpie",
    "<generate-a-long-random-secret>",
    "<provider-access-key-id>",
    "<provider-secret-access-key>"
  ]
  @min_secret_lengths %{
    "DB_PASSWORD" => 16,
    "ELEKTRINE_MASTER_SECRET" => 32,
    "SECRET_KEY_BASE" => 32,
    "SESSION_SIGNING_SALT" => 16,
    "SESSION_ENCRYPTION_SALT" => 16,
    "ENCRYPTION_MASTER_SECRET" => 32,
    "INTERNAL_API_KEY" => 24,
    "CADDY_EDGE_API_KEY" => 24,
    "S3_SECRET_ACCESS_KEY" => 16
  }
  @encryption_secret_keys [
    "ENCRYPTION_MASTER_SECRET",
    "ENCRYPTION_KEY_SALT",
    "ENCRYPTION_SEARCH_SALT"
  ]
  @unencrypted_prod_override_key "ELEKTRINE_ALLOW_UNENCRYPTED_PROD_DATA"

  def validate!(opts \\ []) do
    case validate(opts) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError, format_errors(errors)
    end
  end

  def validate(opts) when is_list(opts) do
    env = Keyword.get(opts, :env, %{})
    environment = Keyword.get(opts, :environment, :prod)

    compiled_modules =
      opts
      |> Keyword.get(:compiled_modules, Modules.all())
      |> Modules.normalize_enabled_modules()

    enabled_modules =
      opts
      |> Keyword.get(:enabled_modules, compiled_modules)
      |> Modules.normalize_enabled_modules()
      |> Enum.filter(&(&1 in compiled_modules))

    errors =
      []
      |> maybe_validate_placeholder_secrets(environment, env)
      |> maybe_validate_secret_lengths(environment, env)
      |> maybe_validate_session_secrets(environment, env)
      |> maybe_validate_encryption_secrets(environment, env)
      |> maybe_validate_email(enabled_modules, env)
      |> maybe_validate_vpn(enabled_modules, env)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp maybe_validate_session_secrets(errors, :prod, env) do
    errors
    |> require_any(
      env,
      ["SESSION_SIGNING_SALT" | @derived_secret_roots],
      "production requires SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET so LiveView and cookie sessions stay consistent across instances"
    )
    |> require_any(
      env,
      ["SESSION_ENCRYPTION_SALT" | @derived_secret_roots],
      "production requires SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET so cookie sessions can be decrypted consistently across instances"
    )
  end

  defp maybe_validate_session_secrets(errors, _environment, _env), do: errors

  defp maybe_validate_encryption_secrets(errors, :prod, env) do
    cond do
      override_enabled?(env, @unencrypted_prod_override_key) ->
        errors

      Enum.any?(@derived_secret_roots, &present?(env_value(env, &1))) ->
        errors

      Enum.all?(@encryption_secret_keys, &present?(env_value(env, &1))) ->
        errors

      true ->
        [
          "production requires ENCRYPTION_MASTER_SECRET, ENCRYPTION_KEY_SALT, and ENCRYPTION_SEARCH_SALT, or ELEKTRINE_MASTER_SECRET; set ELEKTRINE_ALLOW_UNENCRYPTED_PROD_DATA=true only if unencrypted production data is intentional"
          | errors
        ]
    end
  end

  defp maybe_validate_encryption_secrets(errors, _environment, _env), do: errors

  defp maybe_validate_email(errors, enabled_modules, env) do
    if :email in enabled_modules do
      errors
      |> require_any(env, ["PRIMARY_DOMAIN"], "email module requires PRIMARY_DOMAIN")
      |> maybe_validate_haraka(env)
    else
      errors
    end
  end

  defp maybe_validate_haraka(errors, env) do
    errors
    |> require_present(
      env_value(env, "HARAKA_BASE_URL"),
      "email module requires HARAKA_BASE_URL"
    )
    |> require_any(
      env,
      @haraka_outbound_keys ++ @derived_secret_roots,
      "email module requires one of #{Enum.join(@haraka_outbound_keys, ", ")} or ELEKTRINE_MASTER_SECRET"
    )
    |> require_any(
      env,
      @haraka_inbound_keys ++ @derived_secret_roots,
      "email module requires one of #{Enum.join(@haraka_inbound_keys, ", ")} or ELEKTRINE_MASTER_SECRET"
    )
  end

  defp maybe_validate_vpn(errors, enabled_modules, env) do
    if :vpn in enabled_modules do
      fleet_key = env_value(env, "VPN_FLEET_REGISTRATION_KEY")
      self_host_ip = env_value(env, "VPN_SELFHOST_PUBLIC_IP")
      self_host_endpoint = env_value(env, "VPN_SELFHOST_ENDPOINT_HOST")
      self_host_key = env_value(env, "VPN_SELFHOST_PUBLIC_KEY")
      self_host_private_key = env_value(env, "VPN_SELFHOST_PRIVATE_KEY")

      cond do
        present?(fleet_key) ->
          errors

        (present?(self_host_ip) or present?(self_host_endpoint)) and
            (present?(self_host_key) or present?(self_host_private_key)) ->
          errors

        present?(self_host_private_key) or present?(self_host_key) ->
          errors

        true ->
          [
            "vpn module requires either VPN_FLEET_REGISTRATION_KEY or self-hosted WireGuard credentials via VPN_SELFHOST_PRIVATE_KEY/VPN_SELFHOST_PUBLIC_KEY; set VPN_SELFHOST_ENDPOINT_HOST or VPN_SELFHOST_PUBLIC_IP to avoid endpoint autodetection"
            | errors
          ]
      end
    else
      errors
    end
  end

  defp maybe_validate_placeholder_secrets(errors, :prod, env) do
    Enum.reduce(env, errors, fn {key, value}, acc ->
      if secret_key?(key) and known_placeholder?(value) do
        ["production secret #{key} uses a known placeholder value" | acc]
      else
        acc
      end
    end)
  end

  defp maybe_validate_placeholder_secrets(errors, _environment, _env), do: errors

  defp maybe_validate_secret_lengths(errors, :prod, env) do
    Enum.reduce(@min_secret_lengths, errors, fn {key, min_length}, acc ->
      value = env_value(env, key)

      if present?(value) and String.length(value) < min_length do
        ["production secret #{key} must be at least #{min_length} characters" | acc]
      else
        acc
      end
    end)
  end

  defp maybe_validate_secret_lengths(errors, _environment, _env), do: errors

  defp require_any(errors, env, keys, message) do
    if Enum.any?(keys, &present?(env_value(env, &1))) do
      errors
    else
      [message | errors]
    end
  end

  defp secret_key?(key) when is_binary(key) do
    key in ["DATABASE_URL", "DB_PASSWORD"] or
      String.contains?(key, ["SECRET", "PASSWORD", "TOKEN", "API_KEY", "ACCESS_KEY"])
  end

  defp secret_key?(_), do: false

  defp known_placeholder?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    normalized in @known_placeholder_values
  end

  defp known_placeholder?(_), do: false

  defp require_present(errors, value, _message) when is_binary(value) and byte_size(value) > 0,
    do: errors

  defp require_present(errors, value, message) when is_binary(value) do
    if Elektrine.Strings.present?(value) do
      errors
    else
      [message | errors]
    end
  end

  defp require_present(errors, _value, message), do: [message | errors]

  defp env_value(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp present?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present?(_value), do: false

  defp override_enabled?(env, key) do
    env
    |> env_value(key)
    |> truthy?()
  end

  defp truthy?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    normalized in ["1", "true", "yes"]
  end

  defp truthy?(_value), do: false

  defp format_errors(errors) do
    """
    invalid runtime configuration for enabled platform modules:

    #{Enum.map_join(errors, "\n", &"- #{&1}")}
    """
  end
end
