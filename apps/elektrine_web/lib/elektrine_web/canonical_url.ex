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

  defp normalize_port(nil, _scheme), do: nil
  defp normalize_port(port, _scheme) when not is_integer(port), do: nil
  defp normalize_port(port, _scheme), do: port

  defp port_suffix(80, "http"), do: ""
  defp port_suffix(443, "https"), do: ""
  defp port_suffix(nil, _scheme), do: ""
  defp port_suffix(port, _scheme), do: ":#{port}"
end
