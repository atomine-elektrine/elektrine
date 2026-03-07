defmodule ElektrineWeb.ChatLive.IndexTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "message composer route opens the new direct message modal", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/chat?composer=message")

    assert html =~ "New Direct Message"
    assert html =~ "Search users or enter user@domain"
  end
end
