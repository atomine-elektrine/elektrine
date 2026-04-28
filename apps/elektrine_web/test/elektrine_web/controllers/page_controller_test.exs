defmodule ElektrineWeb.PageControllerTest do
  use ElektrineWeb.ConnCase

  alias Elektrine.Profiles.{SitePageVisit, SiteSession}
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

    session = Repo.one!(SiteSession)
    assert session.session_id == visit.session_id
    assert session.entry_host == conn.host
    assert session.entry_path == "/"
    assert session.exit_path == "/"
    assert session.page_views == 1
  end

  test "rolls repeated page views into the active site session", %{conn: conn} do
    conn = get(conn, ~p"/")

    conn =
      conn
      |> recycle()
      |> get(~p"/about")

    assert html_response(conn, 200)
    assert Repo.aggregate(SitePageVisit, :count) == 2
    assert Repo.aggregate(SiteSession, :count) == 1

    session = Repo.one!(SiteSession)
    assert session.page_views == 2
    assert session.entry_path == "/"
    assert session.exit_path == "/about"

    stats = Elektrine.Profiles.get_public_site_view_stats(conn.host)
    assert stats.total_views == 2
    assert stats.unique_visitors == 1
    assert stats.sessions == 1
    assert stats.bounce_rate == 0.0
  end
end
