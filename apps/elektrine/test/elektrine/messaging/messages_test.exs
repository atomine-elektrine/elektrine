defmodule Elektrine.Messaging.MessagesTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging.Messages
  alias Elektrine.Messaging.{Conversation, Message}
  alias Elektrine.Repo

  test "get_user_discussion_posts/2 allows anonymous viewers for public communities" do
    author = AccountsFixtures.user_fixture()

    community =
      %Conversation{}
      |> Conversation.changeset(%{
        name: "public-community-#{System.unique_integer([:positive])}",
        type: "community",
        is_public: true,
        creator_id: author.id
      })
      |> Repo.insert!()

    %Message{}
    |> Message.changeset(%{
      conversation_id: community.id,
      sender_id: author.id,
      post_type: "discussion",
      message_type: "text",
      title: "Hello world",
      content: "first post"
    })
    |> Repo.insert!()

    posts = Messages.get_user_discussion_posts(author.id, limit: 5, viewer_id: nil)

    assert length(posts) == 1
    assert hd(posts).conversation_id == community.id
  end
end
