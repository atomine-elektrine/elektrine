defmodule Elektrine.Social.MessagesTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo
  alias Elektrine.Social.{Conversation, Message}
  alias Elektrine.Social.Messages

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

  test "get_cached_replies_to_activitypub_ids/1 matches parents by activitypub url variants" do
    author = AccountsFixtures.user_fixture()

    conversation =
      %Conversation{}
      |> Conversation.changeset(%{
        type: "dm",
        creator_id: author.id
      })
      |> Repo.insert!()

    parent =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        sender_id: author.id,
        post_type: "post",
        message_type: "text",
        content: "Parent post",
        visibility: "public",
        federated: true,
        activitypub_id: "https://remote.example/objects/parent-123",
        activitypub_url: "https://remote.example/@alice/parent-123"
      })
      |> Repo.insert!()

    reply =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        sender_id: author.id,
        reply_to_id: parent.id,
        post_type: "comment",
        message_type: "text",
        content: "Reply post",
        visibility: "public"
      })
      |> Repo.insert!()

    replies =
      Messages.get_cached_replies_to_activitypub_ids([
        "https://remote.example/@alice/parent-123/",
        "https://remote.example/@alice/parent-123?view=thread"
      ])

    assert Enum.map(replies, & &1.id) == [reply.id]
    assert hd(replies).parent_activitypub_id == parent.activitypub_id
  end
end
