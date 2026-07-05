defmodule ElektrineWeb.LinkControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Profiles
  alias Elektrine.Profiles.ProfileLink
  alias Elektrine.Repo

  test "redirects safe tracked profile links", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: "Link User"})

    {:ok, link} =
      Profiles.create_profile_link(profile.id, %{
        title: "Site",
        url: "https://example.com",
        platform: "website"
      })

    conn = get(conn, ~p"/l/#{link.id}")

    assert redirected_to(conn, 302) == "https://example.com"
  end

  test "redirects normalized legacy profile links", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: "Link User"})

    link =
      Repo.insert!(%ProfileLink{
        profile_id: profile.id,
        title: "Legacy Site",
        url: "  https://example.com/legacy  ",
        platform: "website"
      })

    conn = get(conn, ~p"/l/#{link.id}")

    assert redirected_to(conn, 302) == "https://example.com/legacy"
  end

  test "blocks unsafe legacy profile link redirects", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: "Link User"})

    link =
      Repo.insert!(%ProfileLink{
        profile_id: profile.id,
        title: "Unsafe",
        url: "mailto:test@example.com\r\nLocation:https://evil.test",
        platform: "email"
      })

    conn = get(conn, ~p"/l/#{link.id}")

    assert html_response(conn, 400)
    assert get_resp_header(conn, "location") == []
  end

  test "does not redirect inactive or scheduled links", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: "Link User"})

    {:ok, link} =
      Profiles.create_profile_link(profile.id, %{
        title: "Future",
        url: "https://example.com/future",
        platform: "website",
        active_from: DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    conn = get(conn, ~p"/l/#{link.id}")

    assert html_response(conn, 404)
    assert get_resp_header(conn, "location") == []
  end
end
