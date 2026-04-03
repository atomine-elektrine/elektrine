defmodule ElektrineWeb.PageControllerTest do
  use ElektrineWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Software for sovereignty."

    assert html =~
             ~r/Elektrine is a modular platform for people who want to run communications,\s+identity, and infrastructure under their own control\./

    assert html =~ "Sign up"
  end
end
