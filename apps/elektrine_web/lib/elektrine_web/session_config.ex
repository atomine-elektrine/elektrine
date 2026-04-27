defmodule ElektrineWeb.SessionConfig do
  @moduledoc false

  alias Elektrine.RuntimeEnv
  alias ElektrineWeb.ClientIP

  def session_options(conn \\ nil) do
    base_opts = [
      store: :cookie,
      key: session_cookie_key(),
      signing_salt: signing_salt(),
      max_age: 30 * 24 * 60 * 60,
      same_site: "Lax",
      secure: secure_cookies?(conn),
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
    if RuntimeEnv.environment() == :prod do
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

  def secure_cookies?(conn \\ nil)

  def secure_cookies?(conn) when not is_nil(conn) do
    case RuntimeEnv.optional_boolean("SESSION_COOKIE_SECURE") do
      true ->
        true

      false ->
        false

      _ ->
        https_request?(conn)
    end
  end

  def secure_cookies?(nil) do
    case RuntimeEnv.optional_boolean("SESSION_COOKIE_SECURE") do
      true ->
        true

      false ->
        false

      _ ->
        RuntimeEnv.enforce_https?() or RuntimeEnv.environment() == :prod or
          RuntimeEnv.truthy?("FORCE_SSL")
    end
  end

  defp https_request?(conn) do
    conn.scheme == :https or ClientIP.forwarded_as_https?(conn)
  end

  defp default_signing_salt do
    case RuntimeEnv.environment() do
      :prod -> "chat_auth_signing_salt"
      :test -> "test_signing_salt"
      _ -> "dev_signing_salt"
    end
  end

  defp default_encryption_salt do
    case RuntimeEnv.environment() do
      :prod -> nil
      :test -> "test_encryption_salt"
      _ -> "dev_encryption_salt"
    end
  end
end
