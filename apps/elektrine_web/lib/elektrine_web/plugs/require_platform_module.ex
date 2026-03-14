defmodule ElektrineWeb.Plugs.RequirePlatformModule do
  @moduledoc """
  Returns a 404 when a request targets a module that is disabled for this host.
  """

  import Plug.Conn

  alias ElektrineWeb.PlatformAccess

  def init(opts), do: opts

  def call(conn, _opts) do
    if PlatformAccess.accessible_path?(conn.request_path) do
      conn
    else
      conn
      |> send_resp(:not_found, "Not Found")
      |> halt()
    end
  end
end
