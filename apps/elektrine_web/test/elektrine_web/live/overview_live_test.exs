defmodule ElektrineWeb.OverviewLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/overview")
  end

  test "invalid filter param falls back to default overview content", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview?filter=not-real")

    assert html =~ "Personalized content based on your interests"
    refute html =~ "Your recent activity across all platforms"
  end

  test "invalid like_post id does not crash and shows an error", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    render_hook(view, "like_post", %{"message_id" => "abc"})
    assert render(view) =~ "Invalid post id"
  end
end
