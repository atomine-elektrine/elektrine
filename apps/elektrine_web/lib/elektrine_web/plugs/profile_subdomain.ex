defmodule ElektrineWeb.Plugs.ProfileSubdomain do
  @moduledoc """
  Extracts a user handle from supported profile subdomains for profile pages.

  Subdomains use handles (e.g., maxfield.z.org or maxfield.elektrine.com where
  "maxfield" is the user's handle).
  The subdomain serves the profile page at root (/). Most other paths redirect to the main domain.

  Asset-like paths (e.g., *.jpg, *.css, *.js) are allowed through so static-mode profiles can
  serve their static site assets directly on profile subdomains.
  """

  import Plug.Conn
  import Phoenix.Controller

  @reserved_subdomains ~w(
    www
    admin
    api
    mail
    smtp
    imap
    pop
    pop3
    webmail
    jmap
    caldav
    carddav
    autodiscover
    autoconfig
    static
    assets
    cdn
    images
  )
  @profile_base_domains ~w(z.org elektrine.com)

  def init(opts), do: opts

  def call(conn, _opts) do
    if bypass_subdomain_rewrite?(conn) do
      conn
    else
      {host, _hosts} = get_request_host(conn)

      conn =
        conn
        |> maybe_override_host(host)

      case extract_handle(host) do
        {:ok, handle, base_domain} ->
          path = conn.request_path || ""

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

        {:reserved_subdomain, base_domain} ->
          conn
          |> redirect(external: "https://#{base_domain}/")
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

  # Extract the handle from a subdomain like "maxfield.z.org" or "maxfield.elektrine.com"
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
            {:reserved_subdomain, base_domain}

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

  defp get_request_host(conn) do
    forwarded_hosts =
      [
        "x-forwarded-host",
        "x-original-host",
        "x-host",
        "cf-connecting-host",
        "fly-forwarded-host"
      ]
      |> Enum.flat_map(&get_req_header(conn, &1))

    hosts =
      forwarded_hosts
      |> Enum.flat_map(&parse_hosts/1)
      |> Enum.concat(parse_hosts(forwarded_header_host(conn)))
      |> Enum.concat(parse_hosts(conn.host))
      |> Enum.reject(&(&1 == ""))

    subdomain_host = Enum.find(hosts, &profile_subdomain_host?/1)

    chosen = subdomain_host || Enum.max_by(hosts, &String.length/1, fn -> "" end)
    {chosen, hosts}
  end

  defp profile_subdomain_host?(host) when is_binary(host) do
    profile_base_domain(host) != nil
  end

  defp profile_subdomain_host?(_), do: false

  defp profile_base_domain(host) when is_binary(host) do
    Enum.find(@profile_base_domains, fn base_domain ->
      String.ends_with?(host, ".#{base_domain}")
    end)
  end

  defp profile_base_domain(_), do: nil

  defp parse_hosts(nil), do: []

  defp parse_hosts(host) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&(String.split(&1, ":") |> List.first()))
  end

  defp maybe_override_host(conn, ""), do: conn

  defp maybe_override_host(conn, host) do
    if conn.host == host do
      conn
    else
      %{conn | host: host}
    end
  end

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

  defp forwarded_header_host(conn) do
    conn
    |> get_req_header("forwarded")
    |> List.first()
    |> parse_forwarded_host()
  end

  defp parse_forwarded_host(nil), do: nil
  defp parse_forwarded_host(""), do: nil

  defp parse_forwarded_host(header) do
    header
    |> String.split(";")
    |> Enum.find_value(fn segment ->
      segment
      |> String.trim()
      |> String.split("=", parts: 2)
      |> case do
        ["host", value] -> String.trim(value, "\"")
        _ -> nil
      end
    end)
  end

  defp asset_like_path?(path) when is_binary(path) do
    Path.extname(path) != ""
  end
end
