defmodule Elektrine.Platform.RuntimeConfigValidator do
  @moduledoc false

  alias Elektrine.Platform.Modules

  @supported_email_services ["haraka"]
  @haraka_outbound_keys ["HARAKA_HTTP_API_KEY", "HARAKA_OUTBOUND_API_KEY", "HARAKA_API_KEY"]
  @haraka_inbound_keys ["PHOENIX_API_KEY", "HARAKA_INBOUND_API_KEY", "HARAKA_API_KEY"]

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
      |> maybe_validate_email(enabled_modules, env)
      |> maybe_validate_vpn(enabled_modules, env)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp maybe_validate_email(errors, enabled_modules, env) do
    if :email in enabled_modules do
      email_service = env_value(env, "EMAIL_SERVICE")

      errors
      |> require_any(env, ["PRIMARY_DOMAIN"], "email module requires PRIMARY_DOMAIN")
      |> require_present(email_service, "email module requires EMAIL_SERVICE=haraka")
      |> require_supported_email_service(email_service)
      |> maybe_validate_haraka(email_service, env)
    else
      errors
    end
  end

  defp maybe_validate_haraka(errors, "haraka", env) do
    errors
    |> require_present(
      env_value(env, "HARAKA_BASE_URL"),
      "email module with EMAIL_SERVICE=haraka requires HARAKA_BASE_URL"
    )
    |> require_any(
      env,
      @haraka_outbound_keys,
      "email module with EMAIL_SERVICE=haraka requires one of #{Enum.join(@haraka_outbound_keys, ", ")}"
    )
    |> require_any(
      env,
      @haraka_inbound_keys,
      "email module with EMAIL_SERVICE=haraka requires one of #{Enum.join(@haraka_inbound_keys, ", ")}"
    )
  end

  defp maybe_validate_haraka(errors, _email_service, _env), do: errors

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

  defp require_supported_email_service(errors, nil), do: errors
  defp require_supported_email_service(errors, ""), do: errors

  defp require_supported_email_service(errors, email_service) do
    if email_service in @supported_email_services do
      errors
    else
      [
        "email module does not support EMAIL_SERVICE=#{email_service}; supported values: #{Enum.join(@supported_email_services, ", ")}"
        | errors
      ]
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
