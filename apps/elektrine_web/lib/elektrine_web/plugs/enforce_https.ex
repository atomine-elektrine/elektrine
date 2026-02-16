defmodule ElektrineWeb.Plugs.EnforceHTTPS do
  @moduledoc """
  Redirects plaintext HTTP requests to HTTPS in production.

  Health checks and ACME HTTP-01 challenges remain accessible over HTTP.
  """

  import Plug.Conn

  @behaviour Plug

  @http_allowed_paths ["/health"]
  @acme_prefix "/.well-known/acme-challenge/"

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
    conn.scheme != :https and not forwarded_as_https?(conn)
  end

  defp forwarded_as_https?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [value | _] ->
        value
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> String.downcase() == "https"

      _ ->
        false
    end
  end

  defp http_allowed_path?(path) when path in @http_allowed_paths, do: true
  defp http_allowed_path?(path), do: String.starts_with?(path, @acme_prefix)

  defp https_destination(conn) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "https://#{conn.host}#{conn.request_path}#{query}"
  end
end
