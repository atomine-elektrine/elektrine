defmodule ElektrineWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds comprehensive security headers to all responses.

  Implements defense-in-depth security measures including:
  - Content Security Policy (CSP)
  - Clickjacking protection
  - MIME-type sniffing prevention
  - XSS protection
  - Referrer policy
  - Permissions policy
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_csp_header()
    |> put_hsts_header()
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header(
      "permissions-policy",
      "geolocation=(), microphone=(self), camera=(self), payment=(), usb=(), magnetometer=()"
    )
    |> put_resp_header("x-permitted-cross-domain-policies", "none")

    # COOP/COEP/CORP relaxed for social platform - users post content from any source
    # |> put_resp_header("cross-origin-opener-policy", "same-origin-allow-popups")
    # |> put_resp_header("cross-origin-embedder-policy", "require-corp")
    # |> put_resp_header("cross-origin-resource-policy", "cross-origin")
  end

  # HTTP Strict Transport Security (HSTS)
  # Forces HTTPS connections for 2 years (recommended for preload list)
  defp put_hsts_header(conn) do
    # Only add HSTS header when using HTTPS
    if conn.scheme == :https do
      put_resp_header(
        conn,
        "strict-transport-security",
        "max-age=63072000; includeSubDomains; preload"
      )
    else
      conn
    end
  end

  # Content Security Policy
  # Tailored for Phoenix LiveView applications
  defp put_csp_header(conn) do
    # Get the host for websocket connections
    host = get_host(conn)

    # Build CSP directives
    base_directives = [
      "default-src 'self'",
      # Scripts: allow self, Cloudflare (Turnstile + Insights)
      # Note: 'unsafe-inline' needed for LiveView's inline event handlers
      "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://challenges.cloudflare.com https://static.cloudflareinsights.com https://feed.informer.com blob:",
      # Styles: allow self and unsafe-inline for LiveView and Tailwind
      "style-src 'self' 'unsafe-inline'",
      # Images: allow self, data URIs, HTTPS (for R2/S3 storage, Giphy, avatars)
      "img-src 'self' data: https: blob:",
      # Fonts: allow self and data URIs
      "font-src 'self' data:",
      # Connect: allow self and websockets for LiveView, Cloudflare for Turnstile
      "connect-src 'self' ws://#{host} wss://#{host} https://challenges.cloudflare.com https:",
      # Media: allow self and HTTPS (for video backgrounds from R2/S3)
      "media-src 'self' https: blob:",
      # Frames: allow Cloudflare Turnstile and any HTTPS embeds (for emails/chat/profiles)
      "frame-src 'self' https://challenges.cloudflare.com https:",
      # Child/Worker: allow Cloudflare Turnstile workers
      "child-src 'self' https://challenges.cloudflare.com blob:",
      "worker-src 'self' https://challenges.cloudflare.com blob:",
      # Objects: block all
      "object-src 'none'",
      # Base URI: restrict to self
      "base-uri 'self'",
      # Form actions: restrict to self
      "form-action 'self'",
      # Frame ancestors: same as X-Frame-Options
      "frame-ancestors 'self'"
    ]

    # Add upgrade-insecure-requests in production HTTPS
    directives =
      if conn.scheme == :https do
        base_directives ++ ["upgrade-insecure-requests"]
      else
        base_directives
      end

    csp = Enum.join(directives, "; ")

    put_resp_header(conn, "content-security-policy", csp)
  end

  defp get_host(conn) do
    case get_req_header(conn, "host") do
      [host | _] -> host
      [] -> "localhost:4000"
    end
  end
end
