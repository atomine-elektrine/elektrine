defmodule ElektrineWeb.HashtagLiveShowTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias ElektrineSocialWeb.HashtagLive.Show

  test "malformed hashtag action ids do not crash" do
    user = AccountsFixtures.user_fixture()
    socket = hashtag_socket(user)

    assert {:noreply, socket} =
             Show.handle_event(
               "open_image_modal",
               %{
                 "url" => "/uploads/test.jpg",
                 "images" => "not-json",
                 "index" => "0",
                 "post_id" => "1"
               },
               socket
             )

    assert socket.assigns.flash["error"] == "Unable to open image"

    assert {:noreply, socket} = Show.handle_event("like_post", %{"message_id" => "12abc"}, socket)
    assert socket.assigns.flash["error"] == "Failed to like post"

    assert {:noreply, socket} =
             Show.handle_event("unlike_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to unlike post"

    assert {:noreply, socket} =
             Show.handle_event("boost_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to boost"

    assert {:noreply, socket} =
             Show.handle_event("unboost_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to unboost"

    assert {:noreply, socket} = Show.handle_event("save_post", %{"message_id" => "12abc"}, socket)
    assert socket.assigns.flash["error"] == "Failed to save"

    assert {:noreply, socket} =
             Show.handle_event("unsave_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to unsave"

    assert {:noreply, socket} =
             Show.handle_event(
               "react_to_post",
               %{"message_id" => "12abc", "emoji" => "+1"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to react"

    assert {:noreply, socket} =
             Show.handle_event("quote_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Post not found"

    assert {:noreply, socket} =
             Show.handle_event(
               "vote_poll",
               %{"poll_id" => "12abc", "option_id" => "1"},
               socket
             )

    assert socket.assigns.flash["error"] == "Invalid poll vote"

    assert {:noreply, socket} =
             Show.handle_event("delete_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Post not found"

    assert {:noreply, socket} =
             Show.handle_event("delete_post_admin", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to delete post"
  end

  defp hashtag_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        posts: [],
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        post_reactions: %{},
        show_image_modal: false,
        modal_post: nil
      }
    }
  end
end
