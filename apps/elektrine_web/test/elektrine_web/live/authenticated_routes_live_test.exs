defmodule ElektrineWeb.AuthenticatedRoutesLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  @authenticated_live_routes [
    "/portal",
    "/lists",
    "/lists/1",
    "/account",
    "/account/password",
    "/account/two_factor/setup",
    "/account/two_factor",
    "/account/passkeys",
    "/account/delete",
    "/account/profile/edit",
    "/domains",
    "/analytics/profile",
    "/analytics/domains",
    "/account/storage",
    "/chat",
    "/chat/1",
    "/chat/join/1",
    "/friends",
    "/notifications",
    "/account/app-passwords",
    "/account/nerve",
    "/settings/rss",
    "/email",
    "/email/compose",
    "/email/view/1",
    "/email/1/raw",
    "/email/search",
    "/email/settings",
    "/vpn",
    "/contacts",
    "/contacts/1",
    "/calendar",
    "/search"
  ]

  test "unauthenticated users are redirected from authenticated LiveView routes" do
    Enum.each(@authenticated_live_routes, fn path ->
      assert {:error, reason} = live(build_conn(), path)

      assert match?({:redirect, %{to: "/login"}}, reason) or
               match?({:live_redirect, %{to: "/login"}}, reason),
             "expected #{path} to redirect to /login, got: #{inspect(reason)}"
    end)
  end

  test "banned users are redirected from authenticated LiveView routes" do
    user = AccountsFixtures.user_fixture()
    {:ok, banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

    for path <- ["/portal", "/email", "/account/drive", "/account/proofs"] do
      assert {:error, reason} = live(log_in_user(build_conn(), banned_user), path)

      assert match?({:redirect, %{to: "/login"}}, reason) or
               match?({:live_redirect, %{to: "/login"}}, reason),
             "expected #{path} to reject banned user as unauthenticated, got: #{inspect(reason)}"
    end
  end

  test "suspended users are redirected from authenticated LiveView routes" do
    user = AccountsFixtures.user_fixture()

    {:ok, suspended_user} =
      Accounts.suspend_user(user, %{
        suspended_until: DateTime.add(DateTime.utc_now(), 3600, :second),
        suspension_reason: "security test"
      })

    assert {:error, reason} = live(log_in_user(build_conn(), suspended_user), "/account/drive")

    assert match?({:redirect, %{to: "/login"}}, reason) or
             match?({:live_redirect, %{to: "/login"}}, reason)
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
