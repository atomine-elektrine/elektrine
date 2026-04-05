defmodule ElektrineWeb.CanonicalURL do
  @moduledoc false

  alias ElektrineWeb.Endpoint

  def base_url(scheme_override \\ nil) do
    endpoint_uri = Endpoint.url() |> URI.parse()
    scheme = scheme_override || endpoint_uri.scheme || "https"
    host = endpoint_uri.host || "localhost"
    port = normalize_port(endpoint_uri.port, scheme)

    scheme <> "://" <> host <> port_suffix(port, scheme)
  end

  def url(path, query_string \\ nil, scheme_override \\ nil) do
    query = if query_string in [nil, ""], do: "", else: "?" <> query_string
    base_url(scheme_override) <> path <> query
  end

  def request_url(%Plug.Conn{} = conn, path \\ nil, query_string \\ nil, scheme_override \\ nil) do
    scheme = scheme_override || to_string(conn.scheme || :https)
    host = conn.host || "localhost"
    port = normalize_request_port(conn.port, conn.scheme, scheme)
    request_path = path || conn.request_path || "/"
    query = if query_string in [nil, ""], do: "", else: "?" <> query_string

    scheme <> "://" <> host <> port_suffix(port, scheme) <> request_path <> query
  end

  defp normalize_request_port(port, current_scheme, target_scheme)
       when current_scheme in [:http, :https] do
    case {current_scheme, target_scheme, port} do
      {:http, "https", 80} -> nil
      {:https, "http", 443} -> nil
      _ -> normalize_port(port, target_scheme)
    end
  end

  defp normalize_request_port(port, _current_scheme, target_scheme),
    do: normalize_port(port, target_scheme)

  defp normalize_port(nil, _scheme), do: nil
  defp normalize_port(port, _scheme) when not is_integer(port), do: nil
  defp normalize_port(port, _scheme), do: port

  defp port_suffix(80, "http"), do: ""
  defp port_suffix(443, "https"), do: ""
  defp port_suffix(nil, _scheme), do: ""
  defp port_suffix(port, _scheme), do: ":#{port}"
end
