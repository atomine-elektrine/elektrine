defmodule ElektrineWeb.AuthLive.RegisterSecurityTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "mount tolerates unknown registration error fields in the session", %{conn: conn} do
    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{
        "registration_errors" => %{
          "unknown_field" => ["is invalid"]
        }
      })

    assert {:ok, _view, html} = live(conn, ~p"/register")
    assert html =~ "Register"
  end
end
