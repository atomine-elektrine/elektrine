defmodule ElektrineWeb.Plugs.ProfileSubdomain do
  @moduledoc """
  Extracts a user handle from supported profile subdomains for profile pages.

  Subdomains use handles (e.g., maxfield.example.com where
  "maxfield" is the user's handle).
  The subdomain serves the profile page at root (/). Most other paths redirect to the main domain.

  Asset-like paths (e.g., *.jpg, *.css, *.js) are allowed through so static-mode profiles can
  serve their static site assets directly on profile subdomains.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User

  @reserved_subdomains ~w(
    www
    admin
    pripyat
    api
    mail
    smtp
    imap
    pop
    pop3
    webmail
    jmap
    mta-sts
    caldav
    carddav
    autodiscover
    autoconfig
    static
    assets
    cdn
    images
  )
  def init(opts), do: opts

  def call(conn, _opts) do
    if bypass_subdomain_rewrite?(conn) do
      conn
    else
      host = request_host(conn)

      case extract_handle(host) do
        {:ok, handle, base_domain} ->
          path = conn.request_path || ""

          if subdomain_hosted_by_platform?(handle) do
            cond do
              # Redirect /handle to root (profile is at root on subdomain)
              path == "/#{handle}" ->
                conn
                |> redirect(to: "/")
                |> halt()

              # Allow /profiles/* API calls for follow/followers/etc
              String.starts_with?(path, "/profiles/") ->
                conn
                |> assign(:subdomain_handle, handle)

              # Root path shows the profile
              path == "/" ->
                conn
                |> maybe_rewrite_root_path(handle)
                |> assign(:subdomain_handle, handle)

              # Allow asset-like paths (e.g., /1.jpg, /app.js, /style.css) through so
              # static-mode profiles can serve assets on profile subdomains.
              #
              # Non-static subdomains will typically fall through to 404, which is fine.
              asset_like_path?(path) ->
                conn
                |> assign(:subdomain_handle, handle)

              # Any other path redirects to main domain
              # Subdomains are ONLY for viewing the profile, nothing else
              true ->
                conn
                |> redirect(external: "https://#{base_domain}#{path}")
                |> halt()
            end
          else
            conn
          end

        {:reserved_subdomain, handle, base_domain} ->
          conn
          |> redirect(external: "https://#{base_domain}#{reserved_subdomain_path(handle)}")
          |> halt()

        :not_subdomain ->
          conn

        :invalid_subdomain ->
          conn
          |> put_status(:not_found)
          |> put_view(html: ElektrineWeb.ErrorHTML)
          |> render(:"404", layout: false)
          |> halt()
      end
    end
  end

  # Extract the handle from a subdomain like "maxfield.example.com"
  defp extract_handle(host) do
    case profile_base_domain(host) do
      nil ->
        :not_subdomain

      base_domain ->
        suffix = ".#{base_domain}"
        handle = host |> String.trim_trailing(suffix) |> String.trim()

        cond do
          handle == "" ->
            :invalid_subdomain

          String.contains?(handle, ".") ->
            :not_subdomain

          handle in @reserved_subdomains ->
            {:reserved_subdomain, handle, base_domain}

          true ->
            {:ok, handle, base_domain}
        end
    end
  end

  defp maybe_rewrite_root_path(conn, handle) do
    if conn.request_path == "/" do
      %{conn | request_path: "/subdomain/#{handle}", path_info: ["subdomain", handle]}
    else
      conn
    end
  end

  defp profile_base_domain(host) when is_binary(host) do
    normalized_host = String.downcase(host)

    case Elektrine.Domains.profile_base_domain_for_host(normalized_host) do
      nil ->
        nil

      base_domain ->
        if normalized_host != base_domain and
             String.ends_with?(normalized_host, ".#{base_domain}") do
          base_domain
        else
          nil
        end
    end
  end

  defp profile_base_domain(_), do: nil

  defp request_host(%Plug.Conn{host: host}) when is_binary(host),
    do: host |> String.downcase() |> String.split(":", parts: 2) |> List.first()

  defp request_host(_conn), do: ""

  defp bypass_subdomain_rewrite?(conn) do
    path = conn.request_path || ""

    cond do
      String.starts_with?(path, "/live") -> true
      String.starts_with?(path, "/socket") -> true
      String.starts_with?(path, "/phoenix") -> true
      String.starts_with?(path, "/assets") -> true
      String.starts_with?(path, "/profiles/") -> true
      String.starts_with?(path, "/uploads") -> true
      # ActivityPub federation endpoints - must bypass subdomain rewrite
      path == "/inbox" -> true
      String.starts_with?(path, "/users/") -> true
      String.starts_with?(path, "/relay") -> true
      String.starts_with?(path, "/.well-known/") -> true
      String.starts_with?(path, "/nodeinfo") -> true
      String.starts_with?(path, "/c/") -> true
      String.starts_with?(path, "/tags/") -> true
      path in ["/favicon.ico", "/robots.txt", "/sitemap.xml"] -> true
      true -> false
    end
  end

  defp asset_like_path?(path) when is_binary(path) do
    Path.extname(path) != ""
  end

  defp subdomain_hosted_by_platform?(handle) when is_binary(handle) do
    case Accounts.get_user_by_handle(handle) do
      %User{} = user -> User.built_in_subdomain_hosted_by_platform?(user)
      _ -> true
    end
  end

  defp subdomain_hosted_by_platform?(_), do: true

  defp reserved_subdomain_path("pripyat"), do: "/pripyat"
  defp reserved_subdomain_path(_), do: "/"
end
