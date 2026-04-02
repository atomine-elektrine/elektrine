defmodule ElektrineWeb.Admin.MonitoringControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Ecto.Query

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo

  describe "GET /pripyat/active-users" do
    test "includes IMAP-only users in active windows and excludes them from never active", %{
      conn: conn
    } do
      admin = admin_user_fixture()
      imap_user = AccountsFixtures.user_fixture()
      never_active_user = AccountsFixtures.user_fixture()
      imap_user_id = imap_user.id

      recent_access =
        DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:second)

      Repo.update_all(
        from(u in User, where: u.id == ^imap_user_id),
        set: [last_imap_access: recent_access, last_login_at: nil, last_pop3_access: nil]
      )

      active_conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/active-users?timeframe=24h")

      active_html = html_response(active_conn, 200)
      assert active_html =~ imap_user.username
      assert active_html =~ "IMAP"

      never_conn =
        conn
        |> recycle()
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/active-users?timeframe=never")

      never_html = html_response(never_conn, 200)
      refute never_html =~ imap_user.username
      assert never_html =~ never_active_user.username
      assert never_html =~ "Never Active"
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
          user.last_password_change && DateTime.to_unix(user.last_password_change)
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
