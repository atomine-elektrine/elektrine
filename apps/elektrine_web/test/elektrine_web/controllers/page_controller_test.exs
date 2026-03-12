defmodule ElektrineWeb.PageControllerTest do
  use ElektrineWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Software you can own."

    assert html =~
             ~r/Elektrine is a modular platform for operators who want to run internet\s+services under their own control\./

    assert html =~ "Sign in"
  end
end
