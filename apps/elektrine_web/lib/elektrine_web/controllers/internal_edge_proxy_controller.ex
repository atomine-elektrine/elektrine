defmodule ElektrineWeb.InternalEdgeProxyController do
  use ElektrineWeb, :controller

  alias Elektrine.DNS

  def origin(conn, %{"host" => host}) do
    case DNS.proxied_origin_for_host(host) do
      {:ok, origin} ->
        json(conn, %{origin: origin})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  def origin(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_host"})
  end
end
