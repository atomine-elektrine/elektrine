defmodule ElektrineWeb.MongooseIMAuthControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.Authentication
  alias Elektrine.ActivityPub
  alias Elektrine.API.RateLimiter, as: APIRateLimiter
  alias Elektrine.Auth.RateLimiter, as: AuthRateLimiter
  alias Elektrine.Repo

  setup %{conn: conn} do
    previous_api_key = System.get_env("PHOENIX_API_KEY")
    api_key = "test-mongooseim-internal-api-key"

    System.put_env("PHOENIX_API_KEY", api_key)

    on_exit(fn ->
      if is_nil(previous_api_key) do
        System.delete_env("PHOENIX_API_KEY")
      else
        System.put_env("PHOENIX_API_KEY", previous_api_key)
      end
    end)

    {:ok, conn: authorize(conn, api_key), api_key: api_key}
  end

  describe "POST /_mongooseim/identity/v1/check_credentials" do
    test "requires the internal API key" do
      conn = post(build_conn(), "/_mongooseim/identity/v1/check_credentials", %{})
      assert conn.status == 401
    end

    test "returns true for valid username/password credentials", %{conn: conn} do
      user = user_fixture()

      payload = %{
        "username" => user.username,
        "password" => valid_user_password()
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "true"
    end

    test "returns true for valid user/pass credentials", %{conn: conn} do
      user = user_fixture()

      payload = %{
        "user" => user.username,
        "pass" => valid_user_password()
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "true"
    end

    test "returns true for matrix-style nested payload", %{conn: conn} do
      user = user_fixture()

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => valid_user_password()
        }
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "true"
    end

    test "returns true for valid app password", %{conn: conn} do
      user = user_fixture()

      {:ok, app_password} =
        Authentication.create_app_password(user.id, %{name: "MongooseIM Client"})

      payload = %{
        "user" => user.username,
        "pass" => app_password.token
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "true"
    end

    test "requires app password when 2FA is enabled", %{conn: conn} do
      user = user_fixture()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          two_factor_enabled: true,
          two_factor_secret: Base.encode64("mongooseim-test-secret"),
          two_factor_backup_codes: []
        })
        |> Repo.update()

      payload = %{
        "username" => user.username,
        "password" => valid_user_password()
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "false"
    end

    test "accepts app password when 2FA is enabled", %{conn: conn} do
      user = user_fixture()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          two_factor_enabled: true,
          two_factor_secret: Base.encode64("mongooseim-test-secret"),
          two_factor_backup_codes: []
        })
        |> Repo.update()

      {:ok, app_password} =
        Authentication.create_app_password(user.id, %{name: "MongooseIM Client"})

      payload = %{
        "username" => user.username,
        "password" => app_password.token
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "true"
    end

    test "returns false for wrong password", %{conn: conn} do
      user = user_fixture()

      payload = %{
        "username" => user.username,
        "password" => "wrong-password"
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "false"
    end

    test "returns false for unknown user", %{conn: conn} do
      payload = %{
        "username" => "does-not-exist",
        "password" => "irrelevant"
      }

      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
      response = response(conn, 200)

      assert response == "false"
    end

    test "returns false for malformed payload", %{conn: conn} do
      conn = post(conn, "/_mongooseim/identity/v1/check_credentials", %{})
      response = response(conn, 200)

      assert response == "false"
    end

    test "locks attempts per user localpart", %{conn: conn} do
      user = user_fixture()
      limiter_key = "mongooseim_auth:#{String.downcase(user.username)}"

      AuthRateLimiter.clear_limits(limiter_key)

      on_exit(fn ->
        AuthRateLimiter.clear_limits(limiter_key)
      end)

      payload = %{
        "username" => user.username,
        "password" => "wrong-password"
      }

      Enum.each(1..5, fn _ ->
        attempt_conn = post(conn, "/_mongooseim/identity/v1/check_credentials", payload)
        attempt_response = response(attempt_conn, 200)
        assert attempt_response == "false"
      end)

      status = AuthRateLimiter.get_status(limiter_key)
      assert status.locked == true
    end

    test "applies API rate limiting to mongooseim auth endpoint", %{api_key: api_key} do
      ip_tuple = {203, 0, 113, 88}
      limiter_key = "ip:203.0.113.88"

      APIRateLimiter.clear_limits(limiter_key)

      on_exit(fn ->
        APIRateLimiter.clear_limits(limiter_key)
      end)

      Enum.each(1..60, fn _ ->
        request_conn =
          build_conn()
          |> authorize(api_key)
          |> Map.put(:remote_ip, ip_tuple)
          |> post("/_mongooseim/identity/v1/check_credentials", %{})

        assert request_conn.status == 200
      end)

      limited_conn =
        build_conn()
        |> authorize(api_key)
        |> Map.put(:remote_ip, ip_tuple)
        |> post("/_mongooseim/identity/v1/check_credentials", %{})

      assert limited_conn.status == 429
    end
  end

  describe "MongooseIM native HTTP auth method aliases" do
    test "POST /check_password returns true for valid credentials", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, "/_mongooseim/identity/v1/check_password", %{
          "user" => user.username,
          "server" => ActivityPub.instance_domain(),
          "pass" => valid_user_password()
        })

      assert response(conn, 200) == "true"
    end

    test "GET /check_password is not exposed", %{conn: conn} do
      user = user_fixture()

      conn =
        get(conn, "/_mongooseim/identity/v1/check_password", %{
          "user" => user.username,
          "server" => ActivityPub.instance_domain(),
          "pass" => valid_user_password()
        })

      assert conn.status == 404
    end

    test "GET /user_exists returns true for existing user", %{conn: conn} do
      user = user_fixture()

      conn =
        get(conn, "/_mongooseim/identity/v1/user_exists", %{
          "user" => user.username,
          "server" => ActivityPub.instance_domain()
        })

      assert response(conn, 200) == "true"
    end

    test "GET /user_exists returns false for unknown user", %{conn: conn} do
      conn =
        get(conn, "/_mongooseim/identity/v1/user_exists", %{
          "user" => "does-not-exist",
          "server" => ActivityPub.instance_domain()
        })

      assert response(conn, 200) == "false"
    end
  end

  defp authorize(conn, api_key) do
    put_req_header(conn, "x-api-key", api_key)
  end
end
