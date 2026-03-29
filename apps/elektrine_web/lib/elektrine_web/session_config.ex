defmodule ElektrineWeb.SessionConfig do
  @moduledoc false

  def session_options do
    base_opts = [
      store: :cookie,
      key: session_cookie_key(),
      signing_salt: signing_salt(),
      max_age: 30 * 24 * 60 * 60,
      same_site: "Lax",
      secure: secure_cookies?(),
      http_only: true,
      path: "/",
      extra: "SameSite=Lax"
    ]

    case encryption_salt() do
      nil -> base_opts
      value -> Keyword.put(base_opts, :encryption_salt, value)
    end
  end

  def session_cookie_key do
    if Application.get_env(:elektrine, :environment) == :prod do
      "_elektrine_host"
    else
      "_elektrine_key"
    end
  end

  def signing_salt do
    Application.get_env(:elektrine, :session_signing_salt) || default_signing_salt()
  end

  def encryption_salt do
    Application.get_env(:elektrine, :session_encryption_salt) || default_encryption_salt()
  end

  def secure_cookies? do
    case System.get_env("SESSION_COOKIE_SECURE") do
      "true" ->
        true

      "false" ->
        false

      _ ->
        Application.get_env(:elektrine, :enforce_https, false) or
          Application.get_env(:elektrine, :environment) == :prod or
          System.get_env("FORCE_SSL") == "true"
    end
  end

  defp default_signing_salt do
    cond do
      Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) ->
        case Mix.env() do
          :prod -> "compile_time_placeholder_signing"
          :test -> "test_signing_salt"
          _ -> "dev_signing_salt"
        end

      Application.get_env(:elektrine, :environment) == :prod ->
        "chat_auth_signing_salt"

      true ->
        "dev_signing_salt"
    end
  end

  defp default_encryption_salt do
    cond do
      Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) ->
        case Mix.env() do
          :prod -> "compile_time_placeholder_encryption"
          :test -> "test_encryption_salt"
          _ -> "dev_encryption_salt"
        end

      Application.get_env(:elektrine, :environment) == :prod ->
        nil

      true ->
        "dev_encryption_salt"
    end
  end
end
