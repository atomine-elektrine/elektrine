defmodule ElektrineWeb.Plugs.StaticSitePlug do
  @moduledoc """
  Plug that intercepts profile requests for users with static site mode enabled.
  Serves their custom HTML directly instead of the builder profile.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Elektrine.{Accounts, Profiles, Repo, StaticSites}
  alias Elektrine.Accounts.User
  alias Elektrine.StaticSites.RequestResolver
  alias ElektrineWeb.AtomineGate
  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.UserAuth

  # Allowed content types for static sites (validated on upload, but double-check here)
  @allowed_content_types ~w(
    text/html text/css text/javascript application/javascript application/json
    application/manifest+json application/xml application/rss+xml application/atom+xml
    text/plain text/markdown image/png image/jpeg image/gif image/webp image/avif
    image/svg+xml image/x-icon image/bmp font/woff font/woff2 font/ttf font/otf
    application/font-woff application/font-woff2 application/vnd.ms-fontobject
    application/wasm application/pdf audio/mpeg audio/wav audio/ogg video/mp4 video/webm
  )

  # Content Security Policy for static site HTML.
  # Keep user-controlled pages flexible, but isolate them from the main app and remove the
  # riskiest browser features like object/embed and eval.
  @html_csp [
              "default-src 'self' https: data: blob:",
              "script-src 'self' https: 'unsafe-inline' blob:",
              "style-src 'self' https: 'unsafe-inline'",
              "img-src 'self' https: data: blob:",
              "font-src 'self' https: data:",
              "connect-src 'self' https: wss:",
              "media-src 'self' https: data: blob:",
              "form-action 'self' https:",
              "frame-src 'self' https:",
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

  def call(%{request_path: path, method: "POST"} = conn, _opts) do
    if path == AtomineGate.verify_path() do
      AtomineGate.handle_verify(conn)
    else
      conn
    end
  end

  # Subdomain static site asset serving (e.g., https://handle.example.com/1.jpg)
  # ProfileSubdomain assigns :subdomain_handle for static-mode profiles.
  def call(%{assigns: %{subdomain_handle: handle}, request_path: "/" <> asset_path} = conn, _opts)
      when is_binary(handle) and byte_size(handle) > 0 and byte_size(asset_path) > 0 do
    serve_static_path(conn, handle, asset_path)
  end

  def call(%{request_path: "/" <> handle} = conn, _opts) when byte_size(handle) > 0 do
    # Only intercept if this looks like a profile handle (no further path segments for index)
    # and it's not a reserved path
    cond do
      # Skip if there are path segments after the handle
      String.contains?(handle, "/") ->
        maybe_serve_static_path(conn, handle)

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
        serve_static_path(conn, handle, "/")

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

  defp check_and_serve_static_profile(conn, handle) do
    serve_static_path(conn, handle, "/")
  end

  defp maybe_serve_static_path(conn, path) do
    # Check if this is a static asset request for a user's static site
    # Format: /username/path/to/file.css
    case String.split(path, "/", parts: 2) do
      [handle, asset_path] ->
        if reserved_path?(handle) do
          conn
        else
          serve_static_path(conn, handle, asset_path)
        end

      _ ->
        conn
    end
  end

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve_static_path(conn, handle, request_path) do
    conn = ensure_current_user(conn)

    with user when not is_nil(user) <- static_site_user(conn, handle),
         true <-
           User.built_in_subdomain_hosted_by_platform?(user) or
             is_binary(conn.assigns[:profile_custom_domain]),
         :ok <- authorize_static_profile(conn, user),
         profile when not is_nil(profile) <- Profiles.get_user_profile(user.id),
         true <- profile.profile_mode == "static" do
      case RequestResolver.resolve(user.id, request_path, mode: profile_host_mode(conn)) do
        {:ok, file} ->
          serve_resolved_file(conn, user, handle, file, request_path)

        :reserved ->
          conn

        :not_found ->
          conn
      end
    else
      _ ->
        conn
    end
  end

  defp static_site_user(%{assigns: %{profile_custom_domain_user_id: user_id}}, _handle)
       when is_integer(user_id) do
    Repo.get(User, user_id)
  end

  defp static_site_user(_conn, handle), do: Accounts.get_user_by_username_or_handle(handle)

  defp ensure_current_user(%{assigns: %{current_user: _}} = conn), do: conn

  defp ensure_current_user(%{private: %{plug_session_fetch: :done}} = conn),
    do: UserAuth.fetch_current_user(conn, [])

  defp ensure_current_user(conn), do: assign(conn, :current_user, nil)

  defp authorize_static_profile(conn, user) do
    current_user = conn.assigns[:current_user]

    case Accounts.can_view_profile?(user, current_user) do
      {:ok, :allowed} -> :ok
      {:error, _reason} -> :error
    end
  end

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  defp serve_resolved_file(conn, user, handle, file, request_path) do
    response_path = static_response_path(request_path)

    if isolate_static_site_on_subdomain?(conn, user, handle) do
      conn
      |> redirect(external: profile_subdomain_url(conn, handle, response_path))
      |> halt()
    else
      case StaticSites.get_file_content(file) do
        {:ok, content} ->
          safe_content_type = sanitize_content_type(file.content_type)

          case AtomineGate.authorize_static_request(
                 conn,
                 user,
                 safe_content_type,
                 response_path
               ) do
            {:ok, conn} ->
              conn
              |> maybe_track_site_visit(user.id, safe_content_type, response_path)
              |> put_resp_content_type(safe_content_type)
              |> put_static_file_headers(safe_content_type)
              |> send_resp(200, content)
              |> halt()

            {:challenge, conn} ->
              conn
          end

        _ ->
          conn
      end
    end
  end

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
          ip_address: ClientIP.client_ip(conn),
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

  defp isolate_static_site_on_subdomain?(conn, user, handle) do
    host = String.downcase(conn.host || "")

    User.built_in_subdomain_hosted_by_platform?(user) and Elektrine.Domains.app_host?(host) and
      conn.assigns[:subdomain_handle] != handle
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

  defp put_static_file_headers(conn, "text/html") do
    put_static_html_headers(conn)
  end

  defp put_static_file_headers(conn, content_type) do
    put_static_asset_headers(conn, content_type)
  end

  defp static_response_path(request_path) when request_path in [nil, "", "/"], do: "/"

  defp static_response_path(request_path) do
    "/" <> String.trim_leading(request_path, "/")
  end

  defp profile_host_mode(conn) do
    if is_binary(conn.assigns[:profile_custom_domain]) do
      :custom_domain
    else
      :subdomain
    end
  end

  # Paths that should never be treated as profile handles
  @reserved_paths ~w(
    admin api account email temp-mail siem search login register password passkey two_factor
    pripyat
    dev www support help about contact terms privacy faq blog docs status
    health ping test settings logout locale onboarding subscribe unsubscribe
    users profiles subdomain calendars calendar contacts addressbooks
    principals activitypub inbox outbox followers following liked
    wellknown .well-known jmap captcha uploads
    portal communities discussions timeline hashtag lists gallery remote chat friends notifications
    media_proxy federation relay tags mail autodiscover oauth webhook vpn
    nodeinfo sitemap.xml robots.txt announcements l c
  )

  defp reserved_path?(path) do
    # Lowercase for comparison
    lower = String.downcase(path)
    lower in @reserved_paths or String.starts_with?(lower, ".")
  end
end
