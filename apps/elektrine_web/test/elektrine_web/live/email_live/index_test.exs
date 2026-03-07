defmodule ElektrineWeb.EmailLive.IndexTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.EmailLive.Index

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/email")
  end

  test "mount redirects when current_user assign is missing" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        flash: %{},
        __changed__: %{active_announcements: true},
        live_action: nil,
        active_announcements: []
      }
    }

    assert {:ok, mounted_socket} = Index.mount(%{}, %{}, socket)
    assert inspect(mounted_socket.redirected) =~ "/login"
  end

  test "calendar task composer route opens the task modal", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/calendar?composer=task")

    assert html =~ "New Task"
    assert html =~ "Add task title"
  end
end
