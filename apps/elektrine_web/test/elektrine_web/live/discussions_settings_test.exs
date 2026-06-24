defmodule ElektrineWeb.DiscussionsSettingsTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias ElektrineSocialWeb.DiscussionsLive.Settings

  test "moderator role actions reject malformed user ids" do
    owner = AccountsFixtures.user_fixture()

    {:ok, community} =
      Messaging.create_group_conversation(
        owner.id,
        %{
          name: "settings-community-#{System.unique_integer([:positive])}",
          description: "Settings test community",
          type: "community",
          community_category: "tech",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    socket = settings_socket(owner, community)

    assert {:noreply, socket} =
             Settings.handle_event(
               "promote_moderator",
               %{"user_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to promote user to moderator"

    assert {:noreply, socket} =
             Settings.handle_event(
               "demote_moderator",
               %{"user_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to remove moderator"
  end

  defp settings_socket(user, community) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        community: community,
        members: []
      }
    }
  end
end
