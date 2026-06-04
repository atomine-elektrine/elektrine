defmodule ElektrineWeb.Plugs.ProfileCSP do
  @moduledoc """
  Custom Content Security Policy for profile pages to allow embeds.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Relaxed CSP for profile pages to allow widget embeds
    directives =
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{ElektrineWeb.Plugs.SecurityHeaders.script_nonce()}' https://open.spotify.com https://www.youtube.com https://s.ytimg.com",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: https: blob:",
        "media-src 'self' https: blob:",
        "font-src 'self' data:",
        "connect-src 'self' wss: https://open.spotify.com https://www.youtube.com https://www.youtube-nocookie.com",
        "frame-src 'self' https://open.spotify.com https://www.youtube.com https://www.youtube-nocookie.com",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'self'"
      ]

    csp =
      conn
      |> maybe_upgrade_insecure_requests(directives)
      |> Enum.join("; ")

    put_resp_header(conn, "content-security-policy", csp)
  end

  defp maybe_upgrade_insecure_requests(conn, directives) do
    if conn.scheme == :https or ElektrineWeb.ClientIP.forwarded_as_https?(conn) do
      directives ++ ["upgrade-insecure-requests"]
    else
      directives
    end
  end
end
