defmodule ElektrineWeb.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :elektrine

  alias Elektrine.Constants

  # Helper to get session options at runtime for LiveView/WebSocket connections
  # Must return a keyword list, not a processed map
  def session_options do
    ElektrineWeb.SessionConfig.session_options()
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [:peer_data, :uri, session: {__MODULE__, :session_options, []}],
      timeout: Constants.websocket_timeout(),
      transport_log: false
    ],
    longpoll: [
      connect_info: [:peer_data, :uri, session: {__MODULE__, :session_options, []}],
      transport_log: false
    ]

  socket "/socket", ElektrineWeb.UserSocket,
    websocket: [connect_info: [:peer_data, session: {__MODULE__, :session_options, []}]],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug ElektrineWeb.Plugs.BlockPrivateUploadPaths

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
      "/_arblarg/events",
      "/_arblarg/events/batch",
      "/_arblarg/ephemeral",
      "/_arblarg/sync"
    ],
    suffixes: ["/inbox"]

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
  plug ElektrineWeb.Plugs.EnforceHTTPS
  plug ElektrineWeb.Plugs.RuntimeSession
  plug ElektrineWeb.Plugs.ProfileSubdomain
  plug ElektrineWeb.Plugs.SecurityHeaders
  plug ElektrineWeb.Plugs.ProfileCustomDomain
  plug ElektrineWeb.Router
end
