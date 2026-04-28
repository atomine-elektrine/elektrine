defmodule ElektrineWeb.API.AuthControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication
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

    test "hides admin API login outside the private admin network", %{conn: conn, user: user} do
      previous_netbird = Application.get_env(:elektrine, :netbird, [])
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.64.1.0/24"])
      on_exit(fn -> Application.put_env(:elektrine, :netbird, previous_netbird) end)

      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})

      conn =
        %{conn | remote_ip: {203, 0, 113, 10}}
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          username: admin.username,
          password: AccountsFixtures.valid_user_password()
        })

      assert %{"error" => "Not Found"} = json_response(conn, 404)
    end

    test "requires a two-factor code when the account has 2FA enabled", %{conn: conn, user: user} do
      user = enable_two_factor_for_user(user)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          username: user.username,
          password: AccountsFixtures.valid_user_password()
        })

      assert %{"reason" => "two_factor_required"} = json_response(conn, 401)
    end

    test "accepts a valid two-factor code for API login", %{conn: conn, user: user} do
      user = enable_two_factor_for_user(user)
      code = NimbleTOTP.verification_code(decode_two_factor_secret(user.two_factor_secret))

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/login", %{
          username: user.username,
          password: AccountsFixtures.valid_user_password(),
          two_factor_code: code
        })

      assert %{"token" => token} = json_response(conn, 200)
      assert is_binary(token)
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

    test "returns 401 for a banned user token", %{conn: conn, user: user} do
      {:ok, token} = APIAuth.generate_token(user.id)
      {:ok, _banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
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

    test "revoked token cannot access authenticated endpoints", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/auth/logout")

      assert conn.status == 200

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")

      assert conn.status == 401
    end
  end

  defp enable_two_factor_for_user(user) do
    {:ok, setup} = Authentication.initiate_two_factor_setup(user)
    code = NimbleTOTP.verification_code(setup.secret)

    {:ok, updated_user} =
      Authentication.enable_two_factor(user, setup.secret, setup.hashed_backup_codes, code)

    updated_user
  end

  defp decode_two_factor_secret(encoded_secret) do
    case Base.decode64(encoded_secret) do
      {:ok, secret} -> secret
      :error -> encoded_secret
    end
  end
end
