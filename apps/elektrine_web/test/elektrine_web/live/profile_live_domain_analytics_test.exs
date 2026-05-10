defmodule ElektrineWeb.ProfileLiveDomainAnalyticsTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.{Domains, Profiles}

  test "domain counts render in the initial refresh response", %{conn: conn} do
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
    assert html =~ "2 visitors"
    assert html =~ "2 today"
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
