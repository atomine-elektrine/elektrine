defmodule ElektrineWeb.Admin.HarakaController do
  @moduledoc """
  Read-only admin console for Haraka connectivity and built-in domain mail DNS data.
  """

  use ElektrineWeb, :controller

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, _params) do
    render(conn, :index, overview: haraka_admin_module().overview())
  end

  defp haraka_admin_module, do: Module.concat([Elektrine, Email, HarakaAdmin])
end
