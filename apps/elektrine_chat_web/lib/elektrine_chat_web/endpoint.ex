defmodule ElektrineChatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :elektrine_chat_web

  socket "/socket", ElektrineChatWeb.UserSocket,
    websocket: [connect_info: [:peer_data, session: {__MODULE__, :session_options, []}]],
    longpoll: false

  def session_options do
    [
      store: :cookie,
      key: "_elektrine_chat_auth",
      signing_salt: System.get_env("SESSION_SIGNING_SALT") || "chat_auth_signing_salt",
      encryption_salt: System.get_env("SESSION_ENCRYPTION_SALT") || "chat_auth_encryption_salt",
      max_age: 30 * 24 * 60 * 60,
      same_site: "Lax",
      secure: secure_cookies?(),
      http_only: true,
      path: "/",
      extra: "SameSite=Lax"
    ]
  end

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :elektrine
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug ElektrineChatWeb.Plugs.CacheRawBody,
    paths: [
      "/federation/messaging/events",
      "/federation/messaging/sync"
    ]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {ElektrineChatWeb.Plugs.CacheRawBody, :read_body, []},
    length: 25 * 1024 * 1024

  plug Plug.MethodOverride
  plug Plug.Head
  plug ElektrineChatWeb.Router

  defp secure_cookies? do
    case System.get_env("SESSION_COOKIE_SECURE") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:elektrine, :enforce_https, false)
    end
  end
end
