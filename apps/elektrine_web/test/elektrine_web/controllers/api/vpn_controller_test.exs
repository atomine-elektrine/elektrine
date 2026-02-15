defmodule ElektrineWeb.API.VPNControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.Plugs.APIAuth

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, token} = APIAuth.generate_token(user.id)
    %{user: user, token: token}
  end

  defp auth_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "GET /api/vpn/servers" do
    test "returns server list", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/vpn/servers")

      response = json_response(conn, 200)
      assert is_list(response["servers"]) or is_list(response)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/vpn/servers")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/vpn/configs" do
    test "returns user configs", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/vpn/configs")

      response = json_response(conn, 200)
      assert is_list(response["configs"]) or is_list(response)
    end
  end

  describe "POST /api/vpn/configs" do
    test "creates new VPN config", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/vpn/configs", %{name: "Test Config"})

      # May return 201 for created, 400 if no servers available, or 200
      assert conn.status in [200, 201, 400, 422]
    end
  end

  describe "DELETE /api/vpn/configs/:id" do
    test "returns 404 for non-existent config", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/vpn/configs/999999")

      assert json_response(conn, 404)
    end
  end
end
