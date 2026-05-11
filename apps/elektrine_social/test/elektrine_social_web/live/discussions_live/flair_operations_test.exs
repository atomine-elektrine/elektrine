defmodule ElektrineSocialWeb.DiscussionsLive.FlairOperationsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Messaging
  alias ElektrineSocialWeb.DiscussionsLive.Operations.FlairOperations

  test "create_flair rejects unauthenticated public community viewers" do
    owner = user_fixture()
    community = community_conversation_fixture(owner)
    socket = community_socket(community, current_user: nil, is_moderator: false)

    assert {:noreply, _socket} =
             FlairOperations.handle_event("create_flair", %{"name" => "News"}, socket)

    assert Messaging.list_community_flairs(community.id) == []
  end

  test "update_flair rejects flair ids from another community" do
    owner = user_fixture()
    moderator = user_fixture()
    current_community = community_conversation_fixture(owner, %{name: "Current community"})
    other_community = community_conversation_fixture(owner, %{name: "Other community"})

    {:ok, other_flair} =
      Messaging.create_community_flair(%{
        "community_id" => other_community.id,
        "name" => "Original"
      })

    socket = community_socket(current_community, current_user: moderator, is_moderator: true)

    assert {:noreply, _socket} =
             FlairOperations.handle_event(
               "update_flair",
               %{"flair_id" => Integer.to_string(other_flair.id), "name" => "Changed"},
               socket
             )

    assert Messaging.get_community_flair!(other_flair.id).name == "Original"
  end

  defp community_socket(community, overrides) do
    assigns =
      %{
        __changed__: %{},
        flash: %{},
        community: community,
        current_user: nil,
        is_moderator: false,
        flairs: [],
        show_flair_modal: false,
        editing_flair: nil
      }
      |> Map.merge(Map.new(overrides))

    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
