defmodule ElektrineWeb.Plugs.StaticSitePlug do
  @moduledoc """
  Plug that intercepts profile requests for users with static site mode enabled.
  Serves their custom HTML directly instead of the builder profile.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Elektrine.Accounts.User
  alias Elektrine.{Accounts, Profiles, StaticSites}

  # Allowed content types for static sites (validated on upload, but double-check here)
  @allowed_content_types ~w(
    text/html text/css text/javascript application/javascript application/json text/plain
    image/png image/jpeg image/gif image/webp image/svg+xml image/x-icon
    font/woff font/woff2 font/ttf font/otf application/font-woff application/font-woff2
  )

  # Content Security Policy for static site HTML.
  # Keep user-controlled pages flexible, but isolate them from the main app and remove the
  # riskiest browser features like object/embed and eval.
  @html_csp [
              "default-src 'self' https: http: data: blob:",
              "script-src 'self' https: http: 'unsafe-inline' data: blob:",
              "style-src 'self' https: http: 'unsafe-inline'",
              "img-src 'self' https: http: data: blob:",
              "font-src 'self' https: http: data:",
              "connect-src 'self' https: http: wss: ws:",
              "media-src 'self' https: http: data: blob:",
              "form-action 'self' https: http:",
              "frame-src 'self' https: http:",
              "worker-src 'self' blob:",
              "manifest-src 'self' https: http: data: blob:",
              "base-uri 'self'",
              "object-src 'none'",
              "frame-ancestors 'none'"
            ]
            |> Enum.join("; ")

  @svg_csp "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox"

  def init(opts), do: opts

  def html_csp, do: @html_csp

  def put_static_html_headers(conn) do
    conn
    |> put_resp_header("content-security-policy", @html_csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    |> put_resp_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=()"
    )
  end

  def put_static_asset_headers(conn, content_type) do
    conn
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
    |> maybe_put_svg_csp(content_type)
  end

  # Subdomain static site asset serving (e.g., https://handle.example.com/1.jpg)
  # ProfileSubdomain assigns :subdomain_handle for static-mode profiles.
  def call(%{assigns: %{subdomain_handle: handle}, request_path: "/" <> asset_path} = conn, _opts)
      when is_binary(handle) and byte_size(handle) > 0 and byte_size(asset_path) > 0 do
    # Don't hijack app endpoints on subdomains; let them route normally.
    if profile_app_path?(conn, asset_path) do
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
         true <- User.built_in_subdomain_hosted_by_platform?(user) or is_binary(conn.assigns[:profile_custom_domain]),
         profile when not is_nil(profile) <- Profiles.get_user_profile(user.id),
         true <- profile.profile_mode == "static",
         file when not is_nil(file) <- StaticSites.get_file(user.id, "index.html"),
         {:ok, content} <- StaticSites.get_file_content(file) do
      if isolate_static_site_on_subdomain?(conn, user, handle) do
        conn
        |> redirect(external: profile_subdomain_url(conn, handle, "/"))
        |> halt()
      else
        conn = maybe_track_site_visit(conn, user.id, file.content_type, "/")

        # Serve the static site with security headers including CSP
        conn
        |> put_resp_content_type("text/html")
        |> put_static_html_headers()
        |> send_resp(200, content)
        |> halt()
      end
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
        if reserved_path?(handle) do
          conn
        else
          # Validate asset_path doesn't contain path traversal
          if safe_asset_path?(asset_path) do
            serve_asset(conn, handle, asset_path)
          else
            conn
          end
        end

      _ ->
        conn
    end
  end

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve_asset(conn, handle, asset_path) do
    with user when not is_nil(user) <- Accounts.get_user_by_username_or_handle(handle),
         true <- User.built_in_subdomain_hosted_by_platform?(user) or is_binary(conn.assigns[:profile_custom_domain]),
         profile when not is_nil(profile) <- Profiles.get_user_profile(user.id),
         true <- profile.profile_mode == "static",
         file when not is_nil(file) <- resolve_static_site_file(user.id, asset_path),
         {:ok, content} <- StaticSites.get_file_content(file) do
      if isolate_static_site_on_subdomain?(conn, user, handle) do
        conn
        |> redirect(external: profile_subdomain_url(conn, handle, "/#{asset_path}"))
        |> halt()
      else
        conn = maybe_track_site_visit(conn, user.id, file.content_type, "/#{asset_path}")

        # Sanitize content type
        safe_content_type = sanitize_content_type(file.content_type)

        conn
        |> put_resp_content_type(safe_content_type)
        |> put_static_asset_headers(safe_content_type)
        |> send_resp(200, content)
        |> halt()
      end
    else
      _ ->
        conn
    end
  end

  defp resolve_static_site_file(user_id, asset_path)
       when is_integer(user_id) and is_binary(asset_path) do
    asset_path
    |> static_site_lookup_candidates()
    |> Enum.find_value(&StaticSites.get_file(user_id, &1))
  end

  defp resolve_static_site_file(_, _), do: nil

  defp maybe_track_site_visit(conn, profile_user_id, content_type, request_path)
       when is_integer(profile_user_id) and is_binary(content_type) do
    if String.starts_with?(content_type, "text/html") do
      current_user = conn.assigns[:current_user]
      viewer_user_id = if is_map(current_user), do: current_user.id, else: nil
      {conn, visitor_id} = ensure_profile_site_visitor_id(conn)

      _ =
        Profiles.track_profile_site_visit(profile_user_id,
          viewer_user_id: viewer_user_id,
          visitor_id: visitor_id,
          ip_address: remote_ip_string(conn.remote_ip),
          user_agent: get_req_header(conn, "user-agent") |> List.first(),
          referer: get_req_header(conn, "referer") |> List.first(),
          request_host: conn.host,
          request_path: request_path
        )

      conn
    else
      conn
    end
  end

  defp maybe_track_site_visit(conn, _profile_user_id, _content_type, _request_path), do: conn

  defp ensure_profile_site_visitor_id(conn) do
    case conn.private[:plug_session_fetch] do
      :done ->
        case get_session(conn, :profile_site_visitor_id) do
          visitor_id when is_binary(visitor_id) and visitor_id != "" ->
            {conn, visitor_id}

          _ ->
            visitor_id = Ecto.UUID.generate()
            {put_session(conn, :profile_site_visitor_id, visitor_id), visitor_id}
        end

      _ ->
        {conn, Ecto.UUID.generate()}
    end
  end

  defp remote_ip_string(tuple) when is_tuple(tuple),
    do: tuple |> :inet_parse.ntoa() |> to_string()

  defp remote_ip_string(_), do: nil

  defp static_site_lookup_candidates(asset_path) when is_binary(asset_path) do
    trimmed_path = String.trim(asset_path)

    cond do
      trimmed_path == "" ->
        []

      String.ends_with?(trimmed_path, "/") ->
        [trimmed_path <> "index.html"]

      Path.extname(trimmed_path) != "" ->
        [trimmed_path]

      true ->
        [trimmed_path, trimmed_path <> ".html", trimmed_path <> "/index.html"]
    end
  end

  defp static_site_lookup_candidates(_), do: []

  defp isolate_static_site_on_subdomain?(conn, user, handle) do
    host = String.downcase(conn.host || "")
    User.built_in_subdomain_hosted_by_platform?(user) and Elektrine.Domains.app_host?(host) and
      conn.assigns[:subdomain_handle] != handle
  end

  defp profile_app_path?(conn, path) when is_binary(path) do
    if is_binary(conn.assigns[:profile_custom_domain]) do
      custom_domain_app_path?(path)
    else
      subdomain_app_path?(path)
    end
  end

  defp profile_subdomain_url(conn, handle, path) do
    base_domain = profile_base_domain(conn.host)
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "https://#{handle}.#{base_domain}#{path}#{query}"
  end

  defp profile_base_domain(host) do
    Elektrine.Domains.profile_base_domain_for_host(host) ||
      Elektrine.Domains.primary_profile_domain()
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

  defp maybe_put_svg_csp(conn, "image/svg+xml") do
    put_resp_header(conn, "content-security-policy", @svg_csp)
  end

  defp maybe_put_svg_csp(conn, _content_type), do: conn

  # Paths that should never be treated as profile handles
  @reserved_paths ~w(
    admin api account email temp-mail siem search login register password passkey two_factor
    pripyat
    dev www support help about contact terms privacy faq blog docs status
    health ping test settings logout locale onboarding subscribe unsubscribe
    users profiles subdomain calendars calendar contacts addressbooks
    principals activitypub inbox outbox followers following liked
    wellknown .well-known jmap captcha uploads
    overview communities discussions timeline hashtag lists gallery remote chat friends notifications
    media_proxy federation relay tags mail autodiscover oauth webhook vpn
    nodeinfo sitemap.xml robots.txt announcements l c
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

  # Custom root domains are dedicated profile hosts, so standard web files like
  # favicon.ico and robots.txt can be served from the uploaded static site.
  defp custom_domain_app_path?(path) when is_binary(path) do
    path == "" or
      String.starts_with?(path, "live") or
      String.starts_with?(path, "socket") or
      String.starts_with?(path, "phoenix") or
      String.starts_with?(path, "assets") or
      String.starts_with?(path, "profiles/") or
      String.starts_with?(path, "uploads") or
      String.starts_with?(path, "users/") or
      String.starts_with?(path, "relay") or
      String.starts_with?(path, "nodeinfo") or
      String.starts_with?(path, "c/") or
      String.starts_with?(path, "tags/") or
      path == "inbox"
  end
end
