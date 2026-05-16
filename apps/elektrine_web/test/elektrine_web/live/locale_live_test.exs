defmodule ElektrineWeb.LocaleLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  test "LiveViews render with the user's selected locale", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, user} = Accounts.update_user_locale(user, "zh")

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/")

    assert html =~ "账户"
    refute html =~ ">Account<"
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
  end
end
