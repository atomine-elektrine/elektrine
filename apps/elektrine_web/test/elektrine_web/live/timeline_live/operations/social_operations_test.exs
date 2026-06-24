defmodule ElektrineSocialWeb.TimelineLive.Operations.SocialOperationsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineSocialWeb.TimelineLive.Operations.SocialOperations

  test "social operations reject malformed ids" do
    user = AccountsFixtures.user_fixture()
    socket = timeline_socket(user)

    assert {:noreply, socket} =
             SocialOperations.handle_event("toggle_follow", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] ==
             "Couldn't follow this user right now. Please try again."

    assert {:noreply, socket} =
             SocialOperations.handle_event(
               "toggle_follow_remote",
               %{"remote_actor_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to follow user"

    assert {:noreply, socket} =
             SocialOperations.handle_event(
               "discuss_privately",
               %{"message_id" => "1", "target_user_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to start chat"
  end

  defp timeline_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        user_follows: %{},
        pending_follows: %{},
        timeline_posts: [],
        suggested_follows: [],
        timeline_filter: "all",
        timeline_posts_filtered: []
      }
    }
  end
end
