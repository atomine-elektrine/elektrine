defmodule ElektrineWeb.ErrorHTMLTest do
  use ElektrineWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  test "renders 404.html", %{conn: conn} do
    result = render_to_string(ElektrineWeb.ErrorHTML, "404", "html", conn: conn)
    assert result =~ "404"
    assert result =~ "Page Not Found"
  end

  test "renders 500.html", %{conn: conn} do
    result = render_to_string(ElektrineWeb.ErrorHTML, "500", "html", conn: conn)
    assert result =~ "500"
    assert result =~ "Server Error"
  end
end
