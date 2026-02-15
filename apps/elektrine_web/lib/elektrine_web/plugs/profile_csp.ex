defmodule ElektrineWeb.Plugs.ProfileCSP do
  @moduledoc """
  Custom Content Security Policy for profile pages to allow embeds.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Relaxed CSP for profile pages to allow widget embeds
    csp =
      [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://open.spotify.com https://www.youtube.com https://s.ytimg.com https://static.cloudflareinsights.com",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: https: blob:",
        "media-src 'self' https: blob:",
        "font-src 'self' data:",
        "connect-src 'self' wss: https:",
        "frame-src 'self' https:",
        "object-src 'none'",
        "base-uri 'self'"
      ]
      |> Enum.join("; ")

    put_resp_header(conn, "content-security-policy", csp)
  end
end
