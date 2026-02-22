defmodule ElektrineWeb.UserAuthTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias ElektrineWeb.UserAuth

  describe "require_admin_access/2" do
    test "rebinds admin session IP on mismatch instead of logging out", %{conn: conn} do
      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, "test-token")
        |> put_session(:admin_session_ip, "198.51.100.10")
        |> assign(:current_user, admin)
        |> Map.put(:remote_ip, {203, 0, 113, 25})

      conn = UserAuth.require_admin_access(conn, [])

      assert get_session(conn, :user_token) == "test-token"
      assert get_session(conn, :admin_session_ip) == "203.0.113.25"
      assert get_resp_header(conn, "location") == []
      refute conn.halted
    end
  end
end
