defmodule ElektrineChatWeb.HealthController do
  @moduledoc """
  Health check endpoint for Fly.io and load balancers.
  """
  use ElektrineChatWeb, :controller

  def check(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end
end
