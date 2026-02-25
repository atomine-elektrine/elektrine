defmodule ElektrineWeb.AdminLive.FederationTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.AdminLive.Federation

  test "mount loads federation stats without regclass encoding errors" do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: admin_user}}

    assert {:ok, mounted_socket} = Federation.mount(%{}, %{}, socket)

    assert is_map(mounted_socket.assigns.stats)
    assert mounted_socket.assigns.stats.total_actors >= 0
    assert mounted_socket.assigns.stats.total_activities >= 0
  end
end
