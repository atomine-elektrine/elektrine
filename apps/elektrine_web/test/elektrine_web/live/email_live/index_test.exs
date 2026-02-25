defmodule ElektrineWeb.EmailLive.IndexTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ElektrineWeb.EmailLive.Index

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
end
