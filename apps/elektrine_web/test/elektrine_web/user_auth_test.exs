defmodule ElektrineWeb.UserAuthTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias ElektrineWeb.UserAuth

  setup do
    previous = Application.get_env(:elektrine, :admin_security, [])

    Application.put_env(
      :elektrine,
      :admin_security,
      Keyword.merge(previous,
        require_passkey: false,
        access_ttl_seconds: 900,
        elevation_ttl_seconds: 300,
        action_grant_ttl_seconds: 90,
        intent_ttl_seconds: 180,
        replay_ttl_seconds: 600
      )
    )

    on_exit(fn -> Application.put_env(:elektrine, :admin_security, previous) end)
    :ok
  end

  describe "require_admin_access/2" do
    test "rebinds admin session IP on mismatch instead of logging out", %{conn: conn} do
      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})
      now = System.system_time(:second)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, "test-token")
        |> put_session(:admin_session_ip, "198.51.100.10")
        |> put_session(:admin_auth_method, "password")
        |> put_session(:admin_access_expires_at, now + 300)
        |> put_session(:admin_elevated_until, now + 120)
        |> assign(:current_user, admin)
        |> Map.put(:remote_ip, {203, 0, 113, 25})

      conn = UserAuth.require_admin_access(conn, [])

      assert get_session(conn, :user_token) == "test-token"
      assert get_session(conn, :admin_session_ip) == "203.0.113.25"
      assert get_resp_header(conn, "location") == []
      refute conn.halted
    end

    test "redirects admin to elevation when elevation expires", %{conn: conn} do
      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})
      now = System.system_time(:second)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, "test-token")
        |> put_session(:admin_session_ip, "198.51.100.10")
        |> put_session(:admin_auth_method, "password")
        |> put_session(:admin_access_expires_at, now + 300)
        |> put_session(:admin_elevated_until, now - 1)
        |> assign(:current_user, admin)
        |> Map.put(:remote_ip, {203, 0, 113, 25})

      conn = UserAuth.require_admin_access(conn, [])

      assert conn.halted
      assert get_resp_header(conn, "location") != []

      assert String.starts_with?(
               hd(get_resp_header(conn, "location")),
               "/pripyat/security/elevate"
             )
    end
  end

  describe "fetch_current_user/2" do
    test "rejects sessions issued before the last password change", %{conn: conn} do
      user = user_fixture()

      stale_token =
        Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
          "user_id" => user.id,
          "password_changed_at" =>
            DateTime.to_unix(DateTime.add(user.last_password_change, -60, :second))
        })

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, stale_token)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end
  end
end
