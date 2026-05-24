defmodule ElektrineWeb.Plugs.DNSEdgeProxy do
  @moduledoc false

  import Plug.Conn

  alias Elektrine.DNS
  alias ElektrineWeb.AtomineGate
  alias ElektrineWeb.ClientIP

  @hop_by_hop_headers ~w(
    connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade
  )
  @max_request_body_bytes 25 * 1024 * 1024
  @max_response_body_bytes 50 * 1024 * 1024

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.method == "POST" and conn.request_path == AtomineGate.verify_path() do
      AtomineGate.handle_verify(conn)
    else
      host = request_host(conn)

      with true <- edge_proxy_enabled?(),
           false <- bypass_path?(conn.request_path),
           {:ok, origin} <- origin_for_host(host) do
        case AtomineGate.authorize_edge_request(conn, origin, return_path(conn)) do
          {:ok, conn} -> proxy(conn, origin)
          {:challenge, conn} -> conn
        end
      else
        _ -> conn
      end
    end
  end

  defp proxy(conn, origin) do
    case read_proxy_body(conn) do
      {:ok, body, conn} ->
        request =
          Finch.build(conn.method, origin_url(origin, conn), request_headers(conn, origin), body)

        case http_client().request(request, http_opts()) do
          {:ok, %Finch.Response{} = response} ->
            conn
            |> put_proxy_response_headers(response.headers)
            |> send_resp(response.status, response.body)
            |> halt()

          {:error, _reason} ->
            conn
            |> send_resp(502, "Bad Gateway")
            |> halt()
        end

      {:too_large, conn} ->
        conn
        |> send_resp(413, "Payload Too Large")
        |> halt()

      {:error, conn} ->
        conn
        |> send_resp(400, "Bad Request")
        |> halt()
    end
  end

  defp read_proxy_body(conn) do
    case read_body(conn, length: @max_request_body_bytes, read_length: @max_request_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:too_large, conn}
      {:error, _reason} -> {:error, conn}
    end
  end

  defp origin_url(origin, conn) do
    origin.origin_url <> return_path(conn)
  end

  defp return_path(conn) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    conn.request_path <> query
  end

  defp request_headers(conn, origin) do
    forwarded_for = forwarded_for(conn)
    host_header = origin.origin_host_header || request_host(conn)

    conn.req_headers
    |> Enum.reject(fn {name, _value} ->
      hop_by_hop_header?(name) or String.downcase(name) == "host"
    end)
    |> put_header("host", host_header)
    |> put_header("x-forwarded-host", request_host(conn))
    |> put_header("x-forwarded-proto", forwarded_proto(conn))
    |> put_header("x-forwarded-for", forwarded_for)
    |> put_header("x-real-ip", ClientIP.client_ip(conn))
    |> put_header("x-elektrine-edge-proxy", "1")
  end

  defp put_proxy_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      if hop_by_hop_header?(name) do
        conn
      else
        put_resp_header(conn, String.downcase(name), value)
      end
    end)
  end

  defp put_header(headers, name, value) do
    headers
    |> Enum.reject(fn {header_name, _value} -> String.downcase(header_name) == name end)
    |> then(&[{name, value} | &1])
  end

  defp forwarded_for(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [] -> ClientIP.client_ip(conn)
      [existing | _] -> existing <> ", " <> ClientIP.client_ip(conn)
    end
  end

  defp forwarded_proto(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [proto | _] when proto in ["http", "https"] -> proto
      _ -> Atom.to_string(conn.scheme)
    end
  end

  defp bypass_path?("/_edge/" <> _), do: true
  defp bypass_path?("/__atomine_gate/" <> _), do: true
  defp bypass_path?("/api/atomine/" <> _), do: true
  defp bypass_path?("/health"), do: true
  defp bypass_path?(_), do: false

  defp hop_by_hop_header?(name), do: String.downcase(name) in @hop_by_hop_headers

  defp request_host(%Plug.Conn{host: host}) when is_binary(host) do
    host |> String.trim() |> String.downcase() |> String.split(":", parts: 2) |> List.first()
  end

  defp request_host(_conn), do: ""

  defp edge_proxy_enabled? do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:edge_proxy_enabled, true)
  end

  defp origin_for_host(host) do
    case proxy_config(:edge_proxy_origin_resolver, {DNS, :proxied_origin_for_host}) do
      {module, function} -> apply(module, function, [host])
      fun when is_function(fun, 1) -> fun.(host)
    end
  end

  defp http_client do
    proxy_config(:edge_proxy_http_client, __MODULE__.SafeFetchClient)
  end

  defp http_opts do
    [
      max_body_bytes: proxy_config(:edge_proxy_max_response_body_bytes, @max_response_body_bytes),
      pool_timeout: proxy_config(:edge_proxy_connect_timeout_ms, 10_000),
      receive_timeout: proxy_config(:edge_proxy_receive_timeout_ms, 30_000)
    ]
  end

  defp proxy_config(key, default) do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(key, default)
  end

  defmodule SafeFetchClient do
    @moduledoc false

    def request(request, opts),
      do: Elektrine.HTTP.SafeFetch.request(request, Elektrine.Finch, opts)
  end
end
