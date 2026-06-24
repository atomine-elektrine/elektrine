defmodule ElektrineWeb.DiscussionsLive.Operations.MemberOperationsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineSocialWeb.DiscussionsLive.Operations.MemberOperations

  test "toggle follow rejects malformed user ids" do
    user = AccountsFixtures.user_fixture()
    socket = member_socket(user)

    assert {:noreply, socket} =
             MemberOperations.handle_event("toggle_follow", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Couldn't follow right now. Please try again."
  end

  defp member_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        user_follows: %{}
      }
    }
  end
end
