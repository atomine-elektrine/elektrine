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

  alias ElektrineWeb.{ClientIP, Endpoint}

  @script_nonce_key {__MODULE__, :script_nonce}

  def init(opts), do: opts

  def call(conn, _opts) do
    Process.put(@script_nonce_key, nonce())

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

  def script_nonce do
    Process.get(@script_nonce_key) || nonce()
  end

  # HTTP Strict Transport Security (HSTS)
  # Forces HTTPS connections for 2 years (recommended for preload list)
  defp put_hsts_header(conn) do
    # Only add HSTS header when using HTTPS
    if https_request?(conn) do
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
    host = websocket_host(conn)

    # Build CSP directives
    base_directives = [
      "default-src 'self'",
      # Scripts: inline scripts must carry this request nonce.
      "script-src 'self' 'nonce-#{script_nonce()}' https://challenges.cloudflare.com blob:",
      # Styles: allow self and unsafe-inline for LiveView and Tailwind
      "style-src 'self' 'unsafe-inline'",
      # Images: allow self, data URIs, HTTPS (for S3-compatible storage and remote avatars)
      "img-src 'self' data: https: blob:",
      # Fonts: allow self and data URIs
      "font-src 'self' data:",
      # Connect: allow self and the explicit third-party endpoints used by the app
      "connect-src 'self' ws://#{host} wss://#{host} https://challenges.cloudflare.com",
      # Media: allow self and HTTPS (for video backgrounds from S3-compatible storage)
      "media-src 'self' https: blob:",
      # Frames: allow Turnstile and any HTTPS embeds (for emails/chat/profiles)
      "frame-src 'self' https://challenges.cloudflare.com https://www.youtube.com https://www.youtube-nocookie.com https://open.spotify.com",
      # Child/Worker: allow Turnstile workers
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
      if https_request?(conn) do
        base_directives ++ ["upgrade-insecure-requests"]
      else
        base_directives
      end

    csp = Enum.join(directives, "; ")

    put_resp_header(conn, "content-security-policy", csp)
  end

  defp nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp websocket_host(conn) do
    conn
    |> request_host()
    |> normalize_host()
    |> allowed_host()
  end

  defp request_host(conn) do
    case get_req_header(conn, "host") do
      [host | _] -> host
      [] -> nil
    end
  end

  defp allowed_host(host) when is_binary(host) do
    if host in allowed_hosts() do
      host
    else
      default_host()
    end
  end

  defp allowed_host(_), do: default_host()

  defp allowed_hosts do
    ([default_host(), System.get_env("CADDY_ADMIN_HOST")] ++ Elektrine.Domains.app_hosts())
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp default_host,
    do: normalize_host(Endpoint.config(:url)[:host]) || Elektrine.Domains.primary_profile_domain()

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_host(_), do: nil

  defp https_request?(conn), do: conn.scheme == :https or ClientIP.forwarded_as_https?(conn)
end
