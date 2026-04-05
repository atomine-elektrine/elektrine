defmodule ElektrineWeb.Admin.UsersControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.Accounts.TrustLevelLog
  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo
  alias ElektrineWeb.AdminSecurity

  describe "POST /pripyat/users/:id/unban" do
    test "returns to the edit page when unbanning from there", %{conn: conn} do
      admin = admin_user_fixture()
      user = AccountsFixtures.user_fixture()
      {:ok, banned_user} = Accounts.ban_user(user, %{banned_reason: "test"})
      request_path = "/pripyat/users/#{user.id}/unban"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)
        |> Plug.Conn.put_req_header(
          "referer",
          "https://example.com/pripyat/users/#{user.id}/edit"
        )

      action_grant = AdminSecurity.issue_action_grant(conn, admin, "POST", request_path)

      conn =
        post(conn, request_path, %{
          "_admin_action_grant" => action_grant
        })

      assert redirected_to(conn) == "/pripyat/users/#{user.id}/edit"
      refute Accounts.get_user!(banned_user.id).banned
    end
  end

  describe "PUT /pripyat/users/:id" do
    test "persists and audits a manual trust-level change", %{conn: conn} do
      admin = admin_user_fixture()
      user = AccountsFixtures.user_fixture()
      request_path = "/pripyat/users/#{user.id}"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)

      action_grant = AdminSecurity.issue_action_grant(conn, admin, "PUT", request_path)

      conn =
        put(conn, request_path, %{
          "_admin_action_grant" => action_grant,
          "user" => %{
            "username" => user.username,
            "trust_level" => "2"
          }
        })

      assert redirected_to(conn) == "/pripyat/users"
      assert Accounts.get_user!(user.id).trust_level == 2

      log = Repo.get_by!(TrustLevelLog, user_id: user.id)

      assert log.old_level == 0
      assert log.new_level == 2
      assert log.reason == "manual"
    end
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
