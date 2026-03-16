defmodule ElektrineWeb.Plugs.EnforceHTTPS do
  @moduledoc """
  Redirects plaintext HTTP requests to HTTPS in production.

  Health checks remain accessible over HTTP.
  """

  import Plug.Conn

  alias ElektrineWeb.ClientIP

  @behaviour Plug

  @http_allowed_paths ["/health", "/_edge/tls/v1/allow"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if enforce_https?() and insecure_request?(conn) and not http_allowed_path?(conn.request_path) do
      destination = https_destination(conn)

      conn
      |> put_resp_header("location", destination)
      |> send_resp(308, "Permanent Redirect")
      |> halt()
    else
      conn
    end
  end

  defp enforce_https? do
    Application.get_env(:elektrine, :enforce_https, false)
  end

  defp insecure_request?(conn) do
    conn.scheme != :https and not ClientIP.forwarded_as_https?(conn)
  end

  defp http_allowed_path?(path) when path in @http_allowed_paths, do: true
  defp http_allowed_path?(_path), do: false

  defp https_destination(conn) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "https://#{conn.host}#{conn.request_path}#{query}"
  end
end
