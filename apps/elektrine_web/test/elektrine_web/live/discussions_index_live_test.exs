defmodule ElektrineWeb.DiscussionsIndexLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Elektrine.AccountsFixtures

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "stop_propagation is a no-op event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/communities")

    _ = render_hook(view, "stop_propagation", %{})

    assert Process.alive?(view.pid)
  end

  test "signed-in users always see feed view button on communities view", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/communities?view=communities")

    assert has_element?(view, ~s(button[phx-value-view="feed"]))
  end
end
