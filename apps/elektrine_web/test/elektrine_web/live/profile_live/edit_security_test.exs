defmodule ElektrineWeb.ProfileLive.EditSecurityTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Profiles

  test "matches the account settings treatment for active sidebar tabs", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, account_html} =
      conn |> log_in_user(user) |> live(~p"/account?tab=profile")

    {:ok, _view, profile_html} =
      conn |> log_in_user(user) |> live(~p"/account/profile/edit")

    account_classes =
      account_html
      |> Floki.parse_document!()
      |> Floki.find(~s(a[href="/account?tab=profile"]))
      |> Floki.attribute("class")
      |> List.first()
      |> String.split()
      |> MapSet.new()

    profile_classes =
      profile_html
      |> Floki.parse_document!()
      |> Floki.find(~s(button[phx-value-tab="profile"]))
      |> Floki.attribute("class")
      |> List.first()
      |> String.split()
      |> MapSet.new()

    assert profile_classes == account_classes
  end

  test "renders extracted effects tab sections", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit?tab=effects")

    assert html =~ "Typewriter Effect"
    assert html =~ "Avatar Effects"
    assert html =~ "Username Effects"
    assert html =~ ~s(name="profile[username_effect]")
  end

  test "ignores forged username color field targets", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit")

    render_hook(view, "update_username_color", %{
      "_target" => ["profile", "unknown_field"],
      "profile" => %{"unknown_field" => "#ffffff"}
    })

    assert render(view) =~ "Profile"
  end

  test "ignores malformed effect values", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit")

    profile = Profiles.get_user_profile(user.id)

    render_hook(view, "update_effect", %{
      "_target" => ["profile", "profile_opacity"],
      "profile" => %{"profile_opacity" => "not-a-number"}
    })

    assert Profiles.get_user_profile(user.id).profile_opacity == profile.profile_opacity
  end

  test "ignores malformed profile content ids", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit")

    for {event, params} <- [
          {"edit_link", %{"id" => "12abc"}},
          {"delete_link", %{"id" => "12abc"}},
          {"delete_widget", %{"id" => "12abc"}},
          {"toggle_badge_visibility", %{"badge_id" => "12abc"}},
          {"reorder_link", %{"id" => "12abc", "direction" => "up"}},
          {"reorder_links", %{"ids" => ["12abc", "34"]}},
          {"reorder_widget", %{"id" => "12abc", "direction" => "down"}}
        ] do
      render_hook(view, event, params)
    end

    assert render(view) =~ "Profile"
  end

  test "renders profile privacy and federation controls", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{profile_visibility: "followers"})
    {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit")

    assert html =~ "Federation Preview"
    assert html =~ "Federated actor"
    assert html =~ "Local-only profile features"
    assert html =~ ~s(name="profile[profile_visibility]")
    assert html =~ ~s(name="profile[timeline_visibility]")
    assert html =~ "Followers only"
  end

  test "profile visibility selects update persisted user and profile fields", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit")

    render_hook(view, "update_profile", %{
      "profile" => %{
        "profile_visibility" => "followers",
        "timeline_visibility" => "hidden",
        "community_posts_visibility" => "hidden",
        "share_visibility" => "hidden",
        "identity_visibility" => "hidden",
        "view_counter_visibility" => "hidden",
        "uid_visibility" => "hidden",
        "layout_height" => "extended"
      }
    })

    updated_user = Accounts.get_user!(user.id)
    updated_profile = Profiles.get_user_profile(user.id)

    assert updated_user.profile_visibility == "followers"
    assert updated_profile.hide_timeline
    assert updated_profile.hide_community_posts
    assert updated_profile.hide_share_button
    assert updated_profile.hide_avatar
    assert updated_profile.hide_view_counter
    assert updated_profile.hide_uid
    assert updated_profile.extend_layout
  end

  test "reorders links from drag-and-drop ids", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, profile} = Profiles.create_user_profile(user.id, %{display_name: user.username})

    {:ok, first} =
      Profiles.create_profile_link(profile.id, %{
        "title" => "First",
        "url" => "https://first.example",
        "platform" => "website",
        "position" => 0,
        "is_active" => true
      })

    {:ok, second} =
      Profiles.create_profile_link(profile.id, %{
        "title" => "Second",
        "url" => "https://second.example",
        "platform" => "website",
        "position" => 1,
        "is_active" => true
      })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account/profile/edit?tab=content")

    render_hook(view, "reorder_links", %{
      "ids" => [Integer.to_string(second.id), Integer.to_string(first.id)]
    })

    updated_profile = Profiles.get_user_profile(user.id)

    assert Enum.map(updated_profile.links, & &1.id) == [second.id, first.id]
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
