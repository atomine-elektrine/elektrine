defmodule ElektrineWeb.HealthController do
  @moduledoc """
  Health check endpoint for Fly.io and load balancers.
  """
  use ElektrineWeb, :controller

  def check(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end
end
