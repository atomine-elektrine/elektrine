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
    Plug.Session.init(ElektrineWeb.SessionConfig.session_options())
  end

  def call(conn, _session_config) do
    Plug.Session.call(conn, Plug.Session.init(ElektrineWeb.SessionConfig.session_options()))
  end
end
