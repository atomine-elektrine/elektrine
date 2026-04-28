defmodule ElektrineWeb.PageControllerTest do
  use ElektrineWeb.ConnCase

  alias Elektrine.Profiles.SitePageVisit
  alias Elektrine.Repo

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Software for sovereignty."

    assert html =~
             ~r/Elektrine is a modular platform for people who want to run communications,\s+identity, and infrastructure under their own control\./

    assert html =~ "Sign up"
  end

  test "tracks site-wide page visits", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200)
    assert Repo.aggregate(SitePageVisit, :count) == 1

    visit = Repo.one!(SitePageVisit)
    assert visit.request_host == conn.host
    assert visit.request_path == "/"
    assert visit.status == 200
  end
end
