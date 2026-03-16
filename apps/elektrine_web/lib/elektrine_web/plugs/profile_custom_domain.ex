defmodule ElektrineWeb.Plugs.ProfileCustomDomain do
  @moduledoc """
  Serves verified custom profile domains at the root host.

  A verified custom domain maps directly to one user's profile, so `https://example.com/`
  resolves to that profile without a handle path or subdomain.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Elektrine.{Domains, Profiles}
  alias ElektrineWeb.Plugs.StaticSitePlug

  @bypass_prefixes [
    "/assets",
    "/live",
    "/socket",
    "/phoenix",
    "/profiles/",
    "/uploads"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    {host, _hosts} = get_request_host(conn)
    conn = maybe_override_host(conn, host)

    case Profiles.get_verified_custom_domain_for_host(host) do
      %{domain: domain} = custom_domain ->
        if String.downcase(host) == "www." <> domain do
          conn
          |> redirect(
            external: custom_domain_root_url(domain, conn.request_path, conn.query_string)
          )
          |> halt()
        else
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
    case StaticSitePlug.call(conn, []) do
      %{halted: true} = served_conn ->
        served_conn

      _ ->
        if conn.request_path == "/" do
          %{conn | request_path: "/subdomain/#{handle}", path_info: ["subdomain", handle]}
        else
          conn
          |> redirect(external: main_app_url(conn.request_path, conn.query_string))
          |> halt()
        end
    end
  end

  defp bypass_path?(path) when is_binary(path) do
    Enum.any?(@bypass_prefixes, &String.starts_with?(path, &1))
  end

  defp bypass_path?(_), do: false

  defp main_app_url(path, query_string) do
    query = if query_string in [nil, ""], do: "", else: "?" <> query_string
    "https://#{Domains.primary_profile_domain()}#{path}#{query}"
  end

  defp custom_domain_root_url(domain, path, query_string) do
    query = if query_string in [nil, ""], do: "", else: "?" <> query_string
    "https://#{domain}#{path}#{query}"
  end

  defp custom_domain_handle(%{user: %{handle: handle}}) when is_binary(handle) and handle != "",
    do: handle

  defp custom_domain_handle(%{user: %{username: username}}), do: username

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

    chosen = Enum.max_by(hosts, &String.length/1, fn -> "" end)
    {chosen, hosts}
  end

  defp parse_hosts(nil), do: []

  defp parse_hosts(host) when is_binary(host) do
    host
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&(String.split(&1, ":") |> List.first()))
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

  defp maybe_override_host(conn, ""), do: conn

  defp maybe_override_host(conn, host) do
    if conn.host == host do
      conn
    else
      %{conn | host: host}
    end
  end
end
