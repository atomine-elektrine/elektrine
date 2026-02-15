defmodule ElektrineWeb.Plugs.StaticSitePlug do
  @moduledoc """
  Plug that intercepts profile requests for users with static site mode enabled.
  Serves their custom HTML directly instead of the builder profile.
  """

  import Plug.Conn
  alias Elektrine.{Accounts, Profiles, StaticSites}

  # Allowed content types for static sites (validated on upload, but double-check here)
  @allowed_content_types ~w(
    text/html text/css text/javascript application/javascript application/json text/plain
    image/png image/jpeg image/gif image/webp image/svg+xml image/x-icon
    font/woff font/woff2 font/ttf font/otf application/font-woff application/font-woff2
  )

  # Content Security Policy for static site HTML
  # Intentionally permissive: static sites are user-controlled content and often depend on
  # third-party scripts/widgets/CDNs. We still keep frame-ancestors locked to 'self' so other
  # sites cannot iframe user pages by default.
  @html_csp [
              "default-src * data: blob:",
              # Allow inline scripts/styles since users control their own content.
              # Allow any origin so static sites can use arbitrary CDNs/widgets.
              "script-src * 'unsafe-inline' 'unsafe-eval' data: blob:",
              "style-src * 'unsafe-inline'",
              # Allow external images and data URIs
              "img-src * data: blob:",
              # Allow fonts from anywhere and data URIs
              "font-src * data:",
              # Allow XHR/fetch/WebSocket-style connections
              "connect-src *",
              # Allow media from anywhere
              "media-src * data: blob:",
              # Allow third-party form handlers (Netlify Forms, Formspree, etc.)
              "form-action *",
              # Prevent framing by other sites
              "frame-ancestors 'self'",
              # Allow iframes from anywhere (common for embeds/widgets)
              "frame-src *",
              # Restrict base URI (prevents <base href> from rewriting relative URLs unexpectedly)
              "base-uri 'self'"
            ]
            |> Enum.join("; ")

  def init(opts), do: opts

  # Subdomain static site asset serving (e.g., https://handle.z.org/1.jpg)
  # ProfileSubdomain assigns :subdomain_handle for static-mode profiles.
  def call(%{assigns: %{subdomain_handle: handle}, request_path: "/" <> asset_path} = conn, _opts)
      when is_binary(handle) and byte_size(handle) > 0 and byte_size(asset_path) > 0 do
    # Don't hijack app endpoints on subdomains; let them route normally.
    if subdomain_app_path?(asset_path) do
      conn
    else
      if safe_asset_path?(asset_path) do
        serve_asset(conn, handle, asset_path)
      else
        conn
      end
    end
  end

  def call(%{request_path: "/" <> handle} = conn, _opts) when byte_size(handle) > 0 do
    # Only intercept if this looks like a profile handle (no further path segments for index)
    # and it's not a reserved path
    cond do
      # Skip if there are path segments after the handle
      String.contains?(handle, "/") ->
        maybe_serve_static_asset(conn, handle)

      # Skip reserved paths
      reserved_path?(handle) ->
        conn

      # Check if this is a static site profile
      true ->
        check_and_serve_static_profile(conn, handle)
    end
  end

  def call(%{request_path: "/"} = conn, _opts) do
    case conn.assigns[:subdomain_handle] do
      handle when is_binary(handle) and byte_size(handle) > 0 ->
        check_and_serve_static_profile(conn, handle)

      _ ->
        conn
    end
  end

  def call(%{request_path: "/subdomain/" <> handle} = conn, _opts) do
    if String.contains?(handle, "/") do
      conn
    else
      check_and_serve_static_profile(conn, handle)
    end
  end

  def call(conn, _opts), do: conn

  # sobelow_skip ["XSS.SendResp"]
  defp check_and_serve_static_profile(conn, handle) do
    with user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         profile when not is_nil(profile) <- Profiles.get_user_profile(user.id),
         true <- profile.profile_mode == "static",
         file when not is_nil(file) <- StaticSites.get_file(user.id, "index.html"),
         {:ok, content} <- StaticSites.get_file_content(file) do
      # Serve the static site with security headers including CSP
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("content-security-policy", @html_csp)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("x-frame-options", "SAMEORIGIN")
      |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
      |> send_resp(200, content)
      |> halt()
    else
      _ ->
        # Not a static site, continue to LiveView
        conn
    end
  end

  defp maybe_serve_static_asset(conn, path) do
    # Check if this is a static asset request for a user's static site
    # Format: /username/path/to/file.css
    case String.split(path, "/", parts: 2) do
      [handle, asset_path] ->
        # Validate asset_path doesn't contain path traversal
        if safe_asset_path?(asset_path) do
          serve_asset(conn, handle, asset_path)
        else
          conn
        end

      _ ->
        conn
    end
  end

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve_asset(conn, handle, asset_path) do
    with user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         profile when not is_nil(profile) <- Profiles.get_user_profile(user.id),
         true <- profile.profile_mode == "static",
         file when not is_nil(file) <- StaticSites.get_file(user.id, asset_path),
         {:ok, content} <- StaticSites.get_file_content(file) do
      # Sanitize content type
      safe_content_type = sanitize_content_type(file.content_type)

      conn
      |> put_resp_content_type(safe_content_type)
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("x-frame-options", "SAMEORIGIN")
      |> send_resp(200, content)
      |> halt()
    else
      _ ->
        conn
    end
  end

  defp safe_asset_path?(path) do
    # Decode URL-encoded characters first to catch encoded traversal attacks
    decoded_path = URI.decode(path)

    # Normalize the path and check for traversal
    normalized = Path.expand(decoded_path, "/")

    # Prevent directory traversal - path must stay within root
    # Block null bytes and other dangerous characters
    # Only allow safe characters in path
    String.starts_with?(normalized, "/") and
      not String.contains?(decoded_path, "..") and
      not String.starts_with?(decoded_path, "/") and
      not String.contains?(decoded_path, "//") and
      not String.contains?(decoded_path, "\0") and
      not String.contains?(decoded_path, "\\") and
      Regex.match?(~r/^[a-zA-Z0-9_\-\.\/]+$/, decoded_path)
  end

  defp sanitize_content_type(content_type) do
    base_type =
      content_type |> String.split(";") |> List.first() |> String.trim() |> String.downcase()

    if base_type in @allowed_content_types do
      base_type
    else
      "application/octet-stream"
    end
  end

  # Paths that should never be treated as profile handles
  @reserved_paths ~w(
    admin api account email temp-mail siem search login register
    dev www support help about contact terms privacy blog docs status
    health ping test settings logout users calendars addressbooks
    principals activitypub inbox outbox followers following liked
    wellknown .well-known jmap captcha uploads
  )

  defp reserved_path?(path) do
    # Lowercase for comparison
    lower = String.downcase(path)
    lower in @reserved_paths or String.starts_with?(lower, ".")
  end

  # Paths that should always be handled by the main app even on profile subdomains.
  # Keep this conservative to avoid breaking LiveView/websocket/profile APIs.
  defp subdomain_app_path?(path) when is_binary(path) do
    path == "" or
      String.starts_with?(path, "subdomain/") or
      String.starts_with?(path, "live") or
      String.starts_with?(path, "socket") or
      String.starts_with?(path, "phoenix") or
      String.starts_with?(path, "assets") or
      String.starts_with?(path, "profiles/") or
      String.starts_with?(path, "uploads") or
      String.starts_with?(path, "users/") or
      String.starts_with?(path, "relay") or
      String.starts_with?(path, ".well-known/") or
      String.starts_with?(path, "nodeinfo") or
      String.starts_with?(path, "c/") or
      String.starts_with?(path, "tags/") or
      path in ["favicon.ico", "robots.txt", "sitemap.xml", "inbox"]
  end
end
