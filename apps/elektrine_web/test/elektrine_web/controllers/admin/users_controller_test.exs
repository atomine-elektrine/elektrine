defmodule ElektrineWeb.Admin.UsersControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
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
          "https://elektrine.com/pripyat/users/#{user.id}/edit"
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

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "elektrine.com")
  end

  defp log_in_as(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)
    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
