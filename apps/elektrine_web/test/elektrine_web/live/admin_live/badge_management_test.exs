defmodule ElektrineWeb.AdminLive.BadgeManagementTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.AdminLive.BadgeManagement

  test "badge management rejects malformed ids" do
    admin = AccountsFixtures.user_fixture(%{is_admin: true})
    socket = badge_socket(admin)

    assert {:noreply, socket} =
             BadgeManagement.handle_event("select_user", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "User not found"

    assert {:noreply, socket} =
             BadgeManagement.handle_event(
               "grant_badge",
               %{"user_id" => "12abc", "badge_type" => "verified"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to grant badge"

    assert {:noreply, socket} =
             BadgeManagement.handle_event("revoke_badge", %{"badge_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to revoke badge"
  end

  defp badge_socket(admin) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: admin,
        selected_user: nil,
        user_badges: [],
        search_results: []
      }
    }
  end
end
