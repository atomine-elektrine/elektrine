defmodule ElektrineWeb.Plugs.RequireElektrineDomain do
  @moduledoc """
  Plug to ensure that admin routes are only accessible from the elektrine.com domain.
  Returns 404 Not Found if accessed from other domains, making admin routes appear non-existent.
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    host = get_host_from_conn(conn)

    require Logger

    Logger.info(
      "RequireElektrineDomain: host=#{inspect(host)}, allowed=#{elektrine_domain?(host)}"
    )

    if elektrine_domain?(host) do
      conn
    else
      Logger.warning("RequireElektrineDomain: BLOCKED - host #{inspect(host)} is not allowed")

      conn
      |> put_status(:not_found)
      |> put_view(html: ElektrineWeb.ErrorHTML)
      |> render(:"404", layout: false)
      |> halt()
    end
  end

  defp get_host_from_conn(conn) do
    case get_req_header(conn, "host") do
      [host | _] -> host |> String.downcase()
      _ -> conn.host |> to_string() |> String.downcase()
    end
  end

  defp elektrine_domain?(host) do
    # Remove port if present
    domain = host |> String.split(":") |> List.first() |> String.downcase()

    # Check if it's elektrine.com or any subdomain of elektrine.com
    # Allow localhost for development
    # Also allow www.elektrine.com
    domain == "elektrine.com" ||
      domain == "www.elektrine.com" ||
      String.ends_with?(domain, ".elektrine.com") ||
      domain == "localhost" ||
      String.starts_with?(domain, "localhost:")
  end
end
