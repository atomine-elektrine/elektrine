defmodule ElektrineWeb.DiscussionsIndexLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "stop_propagation is a no-op event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/communities")

    _ = render_hook(view, "stop_propagation", %{})

    assert Process.alive?(view.pid)
  end
end
