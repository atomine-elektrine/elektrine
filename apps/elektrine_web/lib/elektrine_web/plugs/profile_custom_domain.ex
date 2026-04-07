defmodule ElektrineWeb.Plugs.ProfileCustomDomain do
  @moduledoc """
  Serves verified custom profile domains at the root host.

  A verified custom domain maps directly to one user's profile, so `https://example.com/`
  resolves to that profile without a handle path or subdomain.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Elektrine.DNS
  alias Elektrine.Profiles
  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.Plugs.StaticSitePlug

  @bypass_prefixes [
    "/assets",
    "/live",
    "/socket",
    "/phoenix",
    "/profiles/",
    "/uploads",
    "/_arblarg",
    "/.well-known/_arblarg"
  ]
  @bypass_paths [
    "/.well-known/webfinger",
    "/.well-known/host-meta",
    "/.well-known/atproto-did"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    host = request_host(conn)

    case Profiles.get_verified_custom_domain_for_host(host) do
      %{domain: domain} = custom_domain ->
        cond do
          force_https_redirect?(conn, domain) ->
            conn
            |> redirect(external: https_url(host, conn.request_path, conn.query_string))
            |> halt()

          String.downcase(host) == "www." <> domain ->
            conn
            |> redirect(
              external: custom_domain_root_url(domain, conn.request_path, conn.query_string)
            )
            |> halt()

          true ->
            handle = custom_domain_handle(custom_domain)

            conn =
              conn
              |> assign(:profile_custom_domain, domain)
              |> assign(:subdomain_handle, handle)

            cond do
              bypass_path?(conn.request_path) ->
                conn

              conn.request_path == "/#{handle}" ->
                conn
                |> redirect(to: "/")
                |> halt()

              true ->
                maybe_serve_custom_profile(conn, handle)
            end
        end

      _ ->
        conn
    end
  end

  defp maybe_serve_custom_profile(conn, handle) do
    if conn.request_path == "/" do
      case StaticSitePlug.call(conn, []) do
        %{halted: true} = served_conn ->
          served_conn

        _ ->
          %{conn | request_path: "/subdomain/#{handle}", path_info: ["subdomain", handle]}
      end
    else
      case StaticSitePlug.call(conn, []) do
        %{halted: true} = served_conn ->
          served_conn

        _ ->
          conn
          |> send_resp(:not_found, "Not Found")
          |> halt()
      end
    end
  end

  defp bypass_path?(path) when is_binary(path) do
    path in @bypass_paths or Enum.any?(@bypass_prefixes, &String.starts_with?(path, &1))
  end

  defp bypass_path?(_), do: false

  defp custom_domain_root_url(domain, path, query_string) do
    query = if query_string in [nil, ""], do: "", else: "?" <> query_string
    "https://#{domain}#{path}#{query}"
  end

  defp https_url(host, path, query_string) do
    query = if query_string in [nil, ""], do: "", else: "?" <> query_string
    "https://#{host}#{path}#{query}"
  end

  defp force_https_redirect?(conn, domain) do
    insecure_request?(conn) and DNS.web_force_https_for_host(domain)
  end

  defp insecure_request?(conn) do
    conn.scheme != :https and not ClientIP.forwarded_as_https?(conn)
  end

  defp custom_domain_handle(%{user: %{handle: handle}}) when is_binary(handle) and handle != "",
    do: handle

  defp custom_domain_handle(%{user: %{username: username}}), do: username

  defp request_host(%Plug.Conn{host: host}) when is_binary(host),
    do: host |> String.downcase() |> String.split(":", parts: 2) |> List.first()

  defp request_host(_conn), do: ""
end
