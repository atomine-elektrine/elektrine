defmodule ElektrineWeb.Admin.VPNControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  describe "GET /pripyat/vpn" do
    test "renders dashboard when quota aggregates are decimals", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/vpn")

      assert html_response(conn, 200) =~ "VPN Management"
    end
  end

  defp make_admin(user) do
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
