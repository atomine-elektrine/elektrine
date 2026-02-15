defmodule Elektrine.SocialFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Elektrine.Social` context.
  """

  import Elektrine.AccountsFixtures
  alias Elektrine.Repo
  alias Elektrine.Messaging.{Conversation, Message}

  @doc """
  Creates a timeline conversation for a user.
  """
  def timeline_conversation_fixture(user) do
    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{
        name: "Timeline",
        type: "timeline",
        creator_id: user.id,
        is_public: true,
        allow_public_posts: true
      })
      |> Repo.insert()

    conversation
  end

  @doc """
  Creates a timeline post (message) for testing.

  ## Options

    * `:user` - The user creating the post. Creates a new user if not provided.
    * `:content` - The post content. Defaults to "Test post content".
    * `:visibility` - Post visibility. Defaults to "public".
    * `:conversation` - Timeline conversation. Creates one if not provided.
  """
  def post_fixture(attrs \\ %{}) do
    user = attrs[:user] || user_fixture()
    content = attrs[:content] || "Test post content #{System.unique_integer([:positive])}"
    visibility = attrs[:visibility] || "public"

    conversation =
      attrs[:conversation] || timeline_conversation_fixture(user)

    {:ok, message} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        sender_id: user.id,
        content: content,
        message_type: "text",
        visibility: visibility,
        post_type: "post",
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })
      |> Repo.insert()

    message |> Repo.preload([:sender, :conversation])
  end

  @doc """
  Creates a post with media URLs for testing.
  Bypasses media URL validation since test URLs aren't on trusted domains.
  """
  def media_post_fixture(attrs \\ %{}) do
    user = attrs[:user] || user_fixture()
    content = attrs[:content] || "Media post content"
    media_urls = attrs[:media_urls] || ["/uploads/test-image.jpg"]

    conversation =
      attrs[:conversation] || timeline_conversation_fixture(user)

    # Use direct insert to bypass media URL validation that requires trusted domains
    {:ok, message} =
      %Message{
        conversation_id: conversation.id,
        sender_id: user.id,
        content: content,
        message_type: "image",
        media_urls: media_urls,
        visibility: "public",
        post_type: "post",
        like_count: 0,
        reply_count: 0,
        share_count: 0
      }
      |> Repo.insert()

    message |> Repo.preload([:sender, :conversation])
  end

  @doc """
  Creates a community conversation for testing discussions.
  """
  def community_conversation_fixture(user, attrs \\ %{}) do
    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{
        name: attrs[:name] || "Test Community",
        type: "community",
        creator_id: user.id,
        is_public: Map.get(attrs, :is_public, true),
        hash: attrs[:hash] || "test_#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    conversation
  end

  @doc """
  Creates a discussion post (for community voting tests).

  ## Options

    * `:user` - The user creating the post. Creates a new user if not provided.
    * `:content` - The post content. Defaults to "Test discussion content".
    * `:community` - Community conversation. Creates one if not provided.
    * `:title` - Discussion title. Defaults to "Test Discussion".
  """
  def discussion_post_fixture(attrs \\ %{}) do
    user = attrs[:user] || user_fixture()
    content = attrs[:content] || "Test discussion content #{System.unique_integer([:positive])}"
    title = attrs[:title] || "Test Discussion"

    community =
      attrs[:community] || community_conversation_fixture(user)

    {:ok, message} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: community.id,
        sender_id: user.id,
        content: content,
        message_type: "text",
        visibility: "public",
        post_type: "discussion",
        title: title,
        upvotes: 0,
        downvotes: 0,
        score: 0,
        reply_count: 0
      })
      |> Repo.insert()

    message |> Repo.preload([:sender, :conversation])
  end
end
