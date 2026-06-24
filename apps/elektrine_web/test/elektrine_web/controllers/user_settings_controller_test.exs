defmodule ElektrineWeb.UserSettingsControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.AccountsFixtures

  describe "POST /announcements/:id/dismiss" do
    test "redirects instead of raising for malformed announcement ids", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_user(user)
        |> Plug.Conn.put_req_header("referer", "https://example.com/account")
        |> post("/announcements/not-an-id/dismiss")

      assert redirected_to(conn) == "/account"
    end
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(
      ElektrineWeb.UserAuth.recent_auth_session_key(),
      System.system_time(:second)
    )
  end
end
