defmodule ElektrineWeb.MatrixWellKnownController do
  use ElektrineWeb, :controller

  alias Elektrine.ActivityPub

  @doc """
  Returns Matrix server delegation metadata.
  GET /.well-known/matrix/server
  """
  def server(conn, _params) do
    json(conn, %{
      "m.server" => matrix_server_delegation()
    })
  end

  @doc """
  Returns Matrix client discovery metadata.
  GET /.well-known/matrix/client
  """
  def client(conn, _params) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> json(%{
      "m.homeserver" => %{
        "base_url" => matrix_client_base_url()
      }
    })
  end

  defp matrix_server_delegation do
    System.get_env("MATRIX_SERVER_DELEGATION") ||
      "matrix.#{ActivityPub.instance_domain()}:8448"
  end

  defp matrix_client_base_url do
    System.get_env("MATRIX_CLIENT_BASE_URL") ||
      "https://matrix.#{ActivityPub.instance_domain()}"
  end
end
