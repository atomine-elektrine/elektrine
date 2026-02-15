defmodule ElektrineWeb.PageControllerTest do
  use ElektrineWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    # Check for Elektrine in the page title or content
    assert html_response(conn, 200) =~ "Elektrine"
  end
end
