defmodule ElektrineWeb.ProfileLiveDomainAnalyticsTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.{DNS, Domains, Profiles}

  test "domain counts load after the initial refresh response", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    host = profile_host(user)

    Profiles.track_site_page_visit(
      visitor_id: "domain-analytics-refresh-a",
      session_id: "domain-analytics-refresh-a",
      request_host: host,
      request_path: "/",
      status: 200
    )

    Profiles.track_site_page_visit(
      visitor_id: "domain-analytics-refresh-b",
      session_id: "domain-analytics-refresh-b",
      request_host: host,
      request_path: "/pricing",
      status: 200
    )

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/analytics/domains")
      |> html_response(200)

    assert html =~ host
    assert html =~ "0 visitors"
    assert html =~ "0 today"

    {:ok, view, _html} =
      conn
      |> recycle()
      |> log_in_user(user)
      |> live(~p"/analytics/domains")

    html = render(view)

    assert html =~ host
    assert html =~ "2 visitors"
    assert html =~ "2 today"
  end

  test "switching to another domain keeps the breakdown counts instead of resetting to zero", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()

    # The user has an auto-created built-in DNS zone; add a second zone named to sort
    # last so the first zone is the one loaded (and cached) on mount, making the
    # second zone the uncached switch target where the reset-to-zero used to happen.
    host_one = DNS.list_user_zones(user) |> List.first() |> Map.fetch!(:domain)

    {:ok, zone_two} =
      DNS.create_zone(user, %{"domain" => "zzz-switch-#{System.unique_integer([:positive])}.com"})

    host_two = zone_two.domain

    # First zone: 2 sessions, second zone: 3 sessions - distinct so we can tell them apart.
    for i <- 1..2 do
      Profiles.track_site_page_visit(
        visitor_id: "one-#{i}",
        session_id: "one-#{i}",
        request_host: host_one,
        request_path: "/",
        status: 200
      )
    end

    for i <- 1..3 do
      Profiles.track_site_page_visit(
        visitor_id: "two-#{i}",
        session_id: "two-#{i}",
        request_host: host_two,
        request_path: "/",
        status: 200
      )
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/analytics/domains")

    html = render(view)
    assert html =~ "2 visitors"
    assert html =~ "3 visitors"

    # Switch to the second (uncached) zone. The per-domain breakdown is global, so the
    # counts must persist through the switch (carried forward) rather than blanking to
    # zero while the selected zone's panel reloads. render_patch returns the pending
    # render before the async reload, which is exactly where the reset used to show.
    patched = render_patch(view, ~p"/analytics/domains?zone_id=#{zone_two.id}")

    assert patched =~ "2 visitors"
    assert patched =~ "3 visitors"
  end

  defp profile_host(user) do
    user
    |> then(&Domains.profile_urls_for_handle(&1.handle || &1.username))
    |> List.first()
    |> URI.parse()
    |> Map.fetch!(:host)
  end

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
