defmodule ElektrineWeb.Admin.AnnouncementsControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Admin
  alias ElektrineWeb.AdminSecurity

  describe "DELETE /pripyat/announcements/:id" do
    test "deletes the announcement when the action grant is present", %{conn: conn} do
      admin = admin_user_fixture()

      {:ok, announcement} =
        Admin.create_announcement(%{
          title: "Delete me",
          content: "Signed admin delete",
          type: "info",
          active: true,
          created_by_id: admin.id
        })

      request_path = "/pripyat/announcements/#{announcement.id}"

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> AdminSecurity.initialize_admin_session(admin, auth_method: :passkey)

      action_grant = AdminSecurity.issue_action_grant(conn, admin, "DELETE", request_path)

      conn =
        delete(conn, request_path, %{
          "_admin_action_grant" => action_grant
        })

      assert redirected_to(conn) == "/pripyat/announcements"

      assert_raise Ecto.NoResultsError, fn ->
        Admin.get_announcement!(announcement.id)
      end
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
