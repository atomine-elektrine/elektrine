defmodule ElektrineWeb.ConnectedAccountControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.AccountsFixtures

  describe "GET /account/connections/:provider/callback" do
    test "rejects malformed OAuth state without raising", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session("connected_account_oauth_state", "expected-state")
        |> get("/account/connections/github/callback", %{"code" => "code", "state" => "short"})

      assert redirected_to(conn) == "/account/proofs"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid OAuth state"
    end
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
