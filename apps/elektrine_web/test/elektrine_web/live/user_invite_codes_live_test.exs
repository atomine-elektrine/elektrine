defmodule ElektrineWeb.UserInviteCodesLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  setup do
    previous_value = Elektrine.System.invite_codes_enabled?()
    previous_min_trust_level = Elektrine.System.self_service_invite_min_trust_level()

    on_exit(fn ->
      Elektrine.System.set_invite_codes_enabled(previous_value)
      Elektrine.System.set_self_service_invite_min_trust_level(previous_min_trust_level)
    end)

    {:ok, _config} = Elektrine.System.set_invite_codes_enabled(true)
    {:ok, _config} = Elektrine.System.set_self_service_invite_min_trust_level(1)
    :ok
  end

  test "trusted user can create and deactivate an invite code from account settings", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    {:ok, trusted_user} = Accounts.admin_update_user(user, %{trust_level: 1})

    {:ok, view, _html} =
      conn
      |> log_in_user(trusted_user)
      |> live(~p"/account?tab=profile")

    assert has_element?(view, "#invite-code-form")

    view
    |> form("#invite-code-form", %{invite: %{note: "Launch friend"}})
    |> render_submit()

    [invite_code] = Accounts.list_user_invite_codes(trusted_user.id)
    assert invite_code.note == "Launch friend"
    assert has_element?(view, "code", invite_code.code)
    assert has_element?(view, "button", "Deactivate")

    view
    |> element("button[phx-click=\"deactivate_invite_code\"]")
    |> render_click()

    [deactivated_invite_code] = Accounts.list_user_invite_codes(trusted_user.id)
    refute deactivated_invite_code.is_active
    assert has_element?(view, "span", "Inactive")
  end

  test "low-trust user sees the invite gate instead of the creation form", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account?tab=profile")

    refute has_element?(view, "#invite-code-form")
    assert render(view) =~ "Invite creation unlocks at TL1"
  end

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
