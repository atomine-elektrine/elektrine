defmodule ElektrineWeb.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :elektrine

  alias Elektrine.Constants

  # Helper to get session options at runtime for LiveView/WebSocket connections
  # Must return a keyword list, not a processed map
  def session_options do
    base_opts = [
      store: :cookie,
      key: session_cookie_key(),
      signing_salt: System.get_env("SESSION_SIGNING_SALT") || get_default_signing_salt(),
      encryption_salt: System.get_env("SESSION_ENCRYPTION_SALT") || get_default_encryption_salt(),
      # 30 days - standard for web apps
      max_age: 30 * 24 * 60 * 60,
      same_site: "Lax",
      secure: secure_cookies?(),
      http_only: true,
      path: "/",
      extra: "SameSite=Lax"
    ]

    # Intentionally host-only (no Domain=.z.org) to isolate user subdomains from app sessions.
    base_opts
  end

  defp session_cookie_key do
    if Application.get_env(:elektrine, :environment) == :prod do
      "_elektrine_host"
    else
      "_elektrine_key"
    end
  end

  defp get_default_signing_salt do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      case Mix.env() do
        :prod -> "compile_time_placeholder_signing"
        :test -> "test_signing_salt"
        _ -> "dev_signing_salt"
      end
    else
      "dev_signing_salt"
    end
  end

  defp get_default_encryption_salt do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      case Mix.env() do
        :prod -> "compile_time_placeholder_encryption"
        :test -> "test_encryption_salt"
        _ -> "dev_encryption_salt"
      end
    else
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

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [:peer_data, session: {__MODULE__, :session_options, []}],
      timeout: Constants.websocket_timeout(),
      transport_log: false
    ],
    longpoll: [
      connect_info: [:peer_data, session: {__MODULE__, :session_options, []}],
      transport_log: false
    ]

  socket "/socket", ElektrineWeb.UserSocket,
    websocket: [connect_info: [:peer_data, session: {__MODULE__, :session_options, []}]],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :elektrine,
    gzip: false,
    only: ElektrineWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :elektrine
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Cache raw body for signature verification on signed webhook/federation endpoints.
  plug ElektrineWeb.Plugs.CacheRawBody,
    paths: [
      "/webhook/stripe",
      "/federation/messaging/events",
      "/federation/messaging/sync"
    ]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {ElektrineWeb.Plugs.CacheRawBody, :read_body, []},
    # Security: Limit request body size to prevent memory exhaustion
    # 25MB limit for all requests including email attachments
    length: 25 * 1024 * 1024

  plug Sentry.PlugContext
  plug Plug.MethodOverride
  plug Plug.Head
  plug ElektrineWeb.Plugs.FlyRedirect
  plug ElektrineWeb.Plugs.EnforceHTTPS
  plug ElektrineWeb.Plugs.RuntimeSession
  plug ElektrineWeb.Plugs.ProfileSubdomain
  plug ElektrineWeb.Plugs.SecurityHeaders
  plug ElektrineWeb.Router
end
