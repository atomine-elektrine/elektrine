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
  @derived_secret_roots ["ELEKTRINE_MASTER_SECRET", "SECRET_KEY_BASE"]

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
      |> maybe_validate_session_secrets(environment, env)
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
      "production requires SESSION_SIGNING_SALT or ELEKTRINE_MASTER_SECRET (SECRET_KEY_BASE also works) so LiveView and cookie sessions stay consistent across instances"
    )
    |> require_any(
      env,
      ["SESSION_ENCRYPTION_SALT" | @derived_secret_roots],
      "production requires SESSION_ENCRYPTION_SALT or ELEKTRINE_MASTER_SECRET (SECRET_KEY_BASE also works) so cookie sessions can be decrypted consistently across instances"
    )
  end

  defp maybe_validate_session_secrets(errors, _environment, _env), do: errors

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
      require_present(
        errors,
        env_value(env, "VPN_FLEET_REGISTRATION_KEY"),
        "vpn module requires VPN_FLEET_REGISTRATION_KEY"
      )
    else
      errors
    end
  end

  defp require_any(errors, env, keys, message) do
    if Enum.any?(keys, &present?(env_value(env, &1))) do
      errors
    else
      [message | errors]
    end
  end

  defp require_present(errors, value, _message) when is_binary(value) and byte_size(value) > 0,
    do: errors

  defp require_present(errors, value, message) when is_binary(value) do
    if String.trim(value) == "" do
      [message | errors]
    else
      errors
    end
  end

  defp require_present(errors, _value, message), do: [message | errors]

  defp env_value(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp format_errors(errors) do
    """
    invalid runtime configuration for enabled platform modules:

    #{Enum.map_join(errors, "\n", &"- #{&1}")}
    """
  end
end
