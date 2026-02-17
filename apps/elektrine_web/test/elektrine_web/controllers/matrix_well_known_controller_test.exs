defmodule ElektrineWeb.MatrixWellKnownControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.ActivityPub

  setup do
    previous_server = System.get_env("MATRIX_SERVER_DELEGATION")
    previous_client = System.get_env("MATRIX_CLIENT_BASE_URL")

    on_exit(fn ->
      restore_env("MATRIX_SERVER_DELEGATION", previous_server)
      restore_env("MATRIX_CLIENT_BASE_URL", previous_client)
    end)

    :ok
  end

  describe "GET /.well-known/matrix/server" do
    test "returns default delegation for current instance domain", %{conn: conn} do
      System.delete_env("MATRIX_SERVER_DELEGATION")

      conn = get(conn, "/.well-known/matrix/server")
      response = json_response(conn, 200)

      assert response["m.server"] == "matrix.#{ActivityPub.instance_domain()}:8448"
    end

    test "returns configured delegation override", %{conn: conn} do
      System.put_env("MATRIX_SERVER_DELEGATION", "matrix.z.org:8448")

      conn = get(conn, "/.well-known/matrix/server")
      response = json_response(conn, 200)

      assert response["m.server"] == "matrix.z.org:8448"
    end
  end

  describe "GET /.well-known/matrix/client" do
    test "returns default homeserver base URL and CORS header", %{conn: conn} do
      System.delete_env("MATRIX_CLIENT_BASE_URL")

      conn = get(conn, "/.well-known/matrix/client")
      response = json_response(conn, 200)

      assert response["m.homeserver"]["base_url"] ==
               "https://matrix.#{ActivityPub.instance_domain()}"

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "returns configured client base URL override", %{conn: conn} do
      System.put_env("MATRIX_CLIENT_BASE_URL", "https://matrix.z.org")

      conn = get(conn, "/.well-known/matrix/client")
      response = json_response(conn, 200)

      assert response["m.homeserver"]["base_url"] == "https://matrix.z.org"
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)

  defp restore_env(key, value) when is_binary(value) do
    System.put_env(key, value)
  end
end
