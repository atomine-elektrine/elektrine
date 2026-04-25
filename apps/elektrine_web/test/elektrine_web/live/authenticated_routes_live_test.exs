defmodule ElektrineWeb.AuthenticatedRoutesLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
    "/account/profile/analytics",
    "/account/storage",
    "/chat",
    "/chat/1",
    "/chat/join/1",
    "/friends",
    "/notifications",
    "/account/app-passwords",
    "/account/password-manager",
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
end
