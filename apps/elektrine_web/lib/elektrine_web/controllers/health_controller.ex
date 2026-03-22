defmodule ElektrineWeb.HealthController do
  @moduledoc """
  Health check endpoint for load balancers and uptime probes.
  """
  use ElektrineWeb, :controller

  def check(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end
end
