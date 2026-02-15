defmodule ElektrineWeb.API.AuthControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.Plugs.APIAuth

  describe "POST /api/auth/login" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "returns token with valid credentials", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          username: user.username,
          password: AccountsFixtures.valid_user_password()
        })

      response = json_response(conn, 200)
      assert response["token"]
      assert response["user"]["id"] == user.id
      assert response["user"]["username"] == user.username
    end

    test "returns 401 with invalid password", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          username: user.username,
          password: "wrongpassword"
        })

      assert conn.status == 401
    end

    test "returns 401 with non-existent user", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          username: "nonexistent",
          password: "anypassword"
        })

      assert conn.status == 401
    end
  end

  describe "GET /api/auth/me" do
    setup do
      user = AccountsFixtures.user_fixture()
      # Generate API token using the plug's token generator
      {:ok, token} = APIAuth.generate_token(user.id)
      %{user: user, token: token}
    end

    test "returns user info with valid token", %{conn: conn, user: user, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      response = json_response(conn, 200)
      assert response["user"]["id"] == user.id
      assert response["user"]["username"] == user.username
    end

    test "returns 401 without token", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert conn.status == 401
    end

    test "returns 401 with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token")
        |> get("/api/auth/me")

      assert conn.status == 401
    end
  end

  describe "POST /api/auth/logout" do
    setup do
      user = AccountsFixtures.user_fixture()
      {:ok, token} = APIAuth.generate_token(user.id)
      %{user: user, token: token}
    end

    test "logs out successfully", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/auth/logout")

      # Should return success
      assert conn.status in [200, 204]
    end
  end
end
