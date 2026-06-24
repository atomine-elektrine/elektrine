defmodule ElektrineWeb.ProfileLive.EditSecurityTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Profiles

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
          {"reorder_widget", %{"id" => "12abc", "direction" => "down"}}
        ] do
      render_hook(view, event, params)
    end

    assert render(view) =~ "Profile"
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
