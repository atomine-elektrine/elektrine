defmodule ElektrineWeb.MatrixInternalAuthControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.Authentication
  alias Elektrine.ActivityPub
  alias Elektrine.API.RateLimiter, as: APIRateLimiter
  alias Elektrine.Auth.RateLimiter, as: AuthRateLimiter
  alias Elektrine.Repo

  describe "POST /_matrix-internal/identity/v1/check_credentials" do
    test "returns success for valid credentials", %{conn: conn} do
      user = user_fixture()

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => valid_user_password()
        }
      }

      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
      response = json_response(conn, 200)

      assert response["auth"]["success"] == true
      assert response["auth"]["mxid"] == "@#{user.username}:#{ActivityPub.instance_domain()}"
      assert response["auth"]["profile"]["display_name"] == user.username
      assert response["auth"]["profile"]["three_pids"] == []
    end

    test "returns success for valid app password", %{conn: conn} do
      user = user_fixture()
      {:ok, app_password} = Authentication.create_app_password(user.id, %{name: "Matrix Client"})

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => app_password.token
        }
      }

      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
      response = json_response(conn, 200)

      assert response["auth"]["success"] == true
      assert response["auth"]["mxid"] == "@#{user.username}:#{ActivityPub.instance_domain()}"
    end

    test "requires app password when 2FA is enabled", %{conn: conn} do
      user = user_fixture()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          two_factor_enabled: true,
          two_factor_secret: Base.encode64("matrix-test-secret"),
          two_factor_backup_codes: []
        })
        |> Repo.update()

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => valid_user_password()
        }
      }

      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
      response = json_response(conn, 200)

      assert response == %{"auth" => %{"success" => false}}
    end

    test "accepts app password when 2FA is enabled", %{conn: conn} do
      user = user_fixture()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          two_factor_enabled: true,
          two_factor_secret: Base.encode64("matrix-test-secret"),
          two_factor_backup_codes: []
        })
        |> Repo.update()

      {:ok, app_password} = Authentication.create_app_password(user.id, %{name: "Matrix Client"})

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => app_password.token
        }
      }

      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
      response = json_response(conn, 200)

      assert response["auth"]["success"] == true
      assert response["auth"]["mxid"] == "@#{user.username}:#{ActivityPub.instance_domain()}"
    end

    test "returns failure for wrong password", %{conn: conn} do
      user = user_fixture()

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => "wrong-password"
        }
      }

      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
      response = json_response(conn, 200)

      assert response == %{"auth" => %{"success" => false}}
    end

    test "returns failure for unknown user", %{conn: conn} do
      payload = %{
        "user" => %{
          "id" => "@does-not-exist:#{ActivityPub.instance_domain()}",
          "password" => "irrelevant"
        }
      }

      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
      response = json_response(conn, 200)

      assert response == %{"auth" => %{"success" => false}}
    end

    test "returns failure for malformed payload", %{conn: conn} do
      conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", %{})
      response = json_response(conn, 200)

      assert response == %{"auth" => %{"success" => false}}
    end

    test "locks matrix auth attempts per user localpart", %{conn: conn} do
      user = user_fixture()
      limiter_key = "matrix_auth:#{String.downcase(user.username)}"

      AuthRateLimiter.clear_limits(limiter_key)

      on_exit(fn ->
        AuthRateLimiter.clear_limits(limiter_key)
      end)

      payload = %{
        "user" => %{
          "id" => "@#{user.username}:#{ActivityPub.instance_domain()}",
          "password" => "wrong-password"
        }
      }

      Enum.each(1..5, fn _ ->
        attempt_conn = post(conn, "/_matrix-internal/identity/v1/check_credentials", payload)
        attempt_response = json_response(attempt_conn, 200)
        assert attempt_response == %{"auth" => %{"success" => false}}
      end)

      status = AuthRateLimiter.get_status(limiter_key)
      assert status.locked == true
    end

    test "applies API rate limiting to matrix internal auth endpoint" do
      ip_tuple = {203, 0, 113, 77}
      limiter_key = "ip:203.0.113.77"

      APIRateLimiter.clear_limits(limiter_key)

      on_exit(fn ->
        APIRateLimiter.clear_limits(limiter_key)
      end)

      Enum.each(1..60, fn _ ->
        request_conn =
          build_conn()
          |> Map.put(:remote_ip, ip_tuple)
          |> post("/_matrix-internal/identity/v1/check_credentials", %{})

        assert request_conn.status == 200
      end)

      limited_conn =
        build_conn()
        |> Map.put(:remote_ip, ip_tuple)
        |> post("/_matrix-internal/identity/v1/check_credentials", %{})

      assert limited_conn.status == 429
    end
  end
end
