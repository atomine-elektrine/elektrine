defmodule ElektrineWeb.Plugs.RuntimeSession do
  @moduledoc """
  Runtime session configuration plug.

  This plug wraps Plug.Session and configures it at application startup (runtime)
  rather than compile time. This ensures that environment variables like
  SESSION_SIGNING_SALT and SESSION_ENCRYPTION_SALT are read from the runtime
  environment, preventing session invalidation on deploys.
  """

  @behaviour Plug

  def init(_opts) do
    # During compilation, use placeholders that will be replaced at actual runtime
    # This allows Docker builds to succeed without secrets
    Plug.Session.init(build_session_opts())
  end

  def call(conn, _session_config) do
    # Re-initialize with fresh environment variables on each call
    # This ensures we always use runtime values, not compile-time values
    Plug.Session.call(conn, Plug.Session.init(build_session_opts()))
  end

  defp build_session_opts do
    base_opts = [
      store: :cookie,
      # In production, use a host-only cookie (no Domain=.z.org) so user subdomains cannot
      # ride the authenticated session via ambient cookies.
      key: session_cookie_key(),
      signing_salt: get_signing_salt(),
      encryption_salt: get_encryption_salt(),
      # 30 days
      max_age: 30 * 24 * 60 * 60,
      same_site: "Lax",
      secure: secure_cookies?(),
      http_only: true,
      path: "/",
      extra: "SameSite=Lax"
    ]

    base_opts
  end

  defp session_cookie_key do
    # Changing the prod cookie name avoids ambiguous "two cookies with the same name"
    # after removing Domain=.z.org (host-only + domain cookie can coexist otherwise).
    if Application.get_env(:elektrine, :environment) == :prod do
      "_elektrine_host"
    else
      "_elektrine_key"
    end
  end

  defp get_signing_salt do
    System.get_env("SESSION_SIGNING_SALT") || default_signing_salt()
  end

  defp get_encryption_salt do
    System.get_env("SESSION_ENCRYPTION_SALT") || default_encryption_salt()
  end

  defp default_signing_salt do
    cond do
      # During compilation, use a placeholder
      Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) ->
        case Mix.env() do
          :prod -> "compile_time_placeholder_signing"
          :test -> "test_signing_salt"
          _ -> "dev_signing_salt"
        end

      # At runtime in a release, require the variable
      Application.get_env(:elektrine, :environment) == :prod ->
        raise "SESSION_SIGNING_SALT must be set in production"

      # Fallback for other environments
      true ->
        "dev_signing_salt"
    end
  end

  defp default_encryption_salt do
    cond do
      # During compilation, use a placeholder
      Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) ->
        case Mix.env() do
          :prod -> "compile_time_placeholder_encryption"
          :test -> "test_encryption_salt"
          _ -> "dev_encryption_salt"
        end

      # At runtime in a release, require the variable
      Application.get_env(:elektrine, :environment) == :prod ->
        raise "SESSION_ENCRYPTION_SALT must be set in production"

      # Fallback for other environments
      true ->
        "dev_encryption_salt"
    end
  end

  defp secure_cookies? do
    case System.get_env("SESSION_COOKIE_SECURE") do
      "true" ->
        true

      "false" ->
        false

      _ ->
        Application.get_env(:elektrine, :enforce_https, false) or
          Application.get_env(:elektrine, :environment) == :prod or
          System.get_env("LETS_ENCRYPT_ENABLED") == "true" or
          System.get_env("FORCE_SSL") == "true"
    end
  end
end
