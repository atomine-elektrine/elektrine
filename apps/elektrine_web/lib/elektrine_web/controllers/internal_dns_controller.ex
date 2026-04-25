defmodule ElektrineWeb.InternalDNSController do
  use ElektrineWeb, :controller

  alias Elektrine.DNS

  def health(conn, _params) do
    health = DNS.health_status()
    status = if health.status == :ok, do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(Map.update!(health, :status, &to_string/1))
  end
end
