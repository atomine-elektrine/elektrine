defmodule ElektrineWeb.Plugs.RequireModuleAccess do
  @moduledoc """
  Enforces admin-managed minimum trust levels for module routes.
  """

  import Plug.Conn

  alias ElektrineWeb.PlatformAccess

  def init(opts), do: opts

  def call(conn, _opts) do
    current_user = conn.assigns[:current_user]

    if PlatformAccess.accessible_path?(conn.request_path, current_user) do
      conn
    else
      conn
      |> send_resp(:forbidden, "Module access requires a higher trust level")
      |> halt()
    end
  end
end
