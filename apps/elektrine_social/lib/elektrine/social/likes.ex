defmodule Elektrine.Social.Likes do
  @moduledoc """
  Handles post likes and related operations.

  This module manages the like system for posts, including:
  - Creating and removing likes
  - Counting likes
  - Checking like status
  - Broadcasting like events via PubSub
  - Federating likes via ActivityPub
  """

  import Ecto.Query, warn: false
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.PostLike

  @doc """
  Likes a post.

  This function:
  1. Creates a like record
  2. Increments the like count on the message
  3. Broadcasts the like event via PubSub (async)
  4. Creates a notification for the post author (async)
  5. Federates the like via ActivityPub (async)

  Returns `{:ok, like}` on success, or `{:error, changeset}` if already liked.
  """
  def like_post(user_id, message_id) do
    %PostLike{}
    |> PostLike.changeset(%{
      user_id: user_id,
      message_id: message_id,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert()
    |> case do
      {:ok, like} ->
        # Increment like count
        increment_like_count(message_id)

        # Broadcast and notify asynchronously (don't block the UI)
        Elektrine.Async.run(fn ->
          broadcast_like_event(:liked, like)

          # Only notify for local posts with sender_id
          message = Repo.get!(Message, message_id)

          if message.sender_id do
            notify_post_like(user_id, message_id)
          end

          # Federate the like to ActivityPub
          Elektrine.ActivityPub.Outbox.federate_like(message_id, user_id)
          # Queue durable Bluesky like sync
          _ = Elektrine.Bluesky.OutboundWorker.enqueue_like(message_id, user_id)
        end)

        {:ok, like}

      error ->
        error
    end
  end

  @doc """
  Unlikes a post.

  Returns `{:ok, deleted_like}` on success, or `{:error, :not_liked}` if not liked.
  """
  def unlike_post(user_id, message_id) do
    case Repo.get_by(PostLike, user_id: user_id, message_id: message_id) do
      nil ->
        {:error, :not_liked}

      like ->
        case Repo.delete(like) do
          {:ok, deleted_like} ->
            # Decrement like count
            decrement_like_count(message_id)

            # Broadcast unlike event asynchronously (don't block the UI)
            Elektrine.Async.run(fn ->
              broadcast_like_event(:unliked, deleted_like)
              # Federate the unlike to ActivityPub
              Elektrine.ActivityPub.Outbox.federate_unlike(message_id, user_id)
              # Queue durable Bluesky unlike sync
              _ = Elektrine.Bluesky.OutboundWorker.enqueue_unlike(message_id, user_id)
            end)

            {:ok, deleted_like}

          error ->
            error
        end
    end
  end

  @doc """
  Checks if user has liked a post.
  """
  def user_liked_post?(user_id, message_id) do
    Repo.exists?(
      from l in PostLike,
        where: l.user_id == ^user_id and l.message_id == ^message_id
    )
  end

  @doc """
  Returns a list of message IDs that the user has liked from the given list.

  Useful for efficiently checking multiple posts at once.
  """
  def list_user_likes(user_id, message_ids) when is_list(message_ids) do
    from(l in PostLike,
      where: l.user_id == ^user_id and l.message_id in ^message_ids,
      select: l.message_id
    )
    |> Repo.all()
  end

  # Private functions

  defp increment_like_count(message_id) do
    from(m in Message, where: m.id == ^message_id)
    |> Repo.update_all(inc: [like_count: 1])
  end

  defp decrement_like_count(message_id) do
    from(m in Message, where: m.id == ^message_id)
    |> Repo.update_all(inc: [like_count: -1])
  end

  defp broadcast_like_event(event_type, like) do
    like = Repo.preload(like, [:message, :user])

    # Broadcast to specific message
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "message:#{like.message_id}",
      {event_type, like}
    )

    message =
      Repo.get!(Message, like.message_id)
      |> Repo.preload([:conversation, :hashtags])

    payload = %{
      message_id: like.message_id,
      like_count: message.like_count,
      sender_id: message.sender_id,
      remote_actor_id: message.remote_actor_id,
      creator_id: message.sender_id || message.remote_actor_id,
      creator_type:
        if(message.federated || not is_nil(message.remote_actor_id), do: "remote", else: "local"),
      hashtags: Enum.map(message.hashtags || [], & &1.normalized_name)
    }

    # Broadcast to timeline feeds if it's a timeline post OR federated post
    # Always use :post_liked event type (whether liking or unliking) for consistency
    if (message.conversation && message.conversation.type == "timeline") || message.federated do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "timeline:all",
        {:post_liked, payload}
      )
    end

    # Broadcast to discussion feeds if it's a discussion post
    if message.conversation && message.conversation.type == "community" do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "discussion:#{message.conversation_id}",
        {:post_liked, payload}
      )
    end
  end

  # Notifies post owner when their post is liked
  defp notify_post_like(liker_id, message_id) do
    # Get the post and users
    message = Repo.get!(Message, message_id)

    # Don't notify if user liked their own post
    # Only notify for local posts (federated posts don't have sender_id)
    if message.sender_id && liker_id != message.sender_id do
      # Check if user wants to be notified about likes
      user = Elektrine.Accounts.get_user!(message.sender_id)

      if Map.get(user, :notify_on_like, true) do
        liker = Elektrine.Accounts.get_user!(liker_id)

        Elektrine.Notifications.create_notification(%{
          user_id: message.sender_id,
          actor_id: liker_id,
          type: "like",
          title: "@#{liker.handle || liker.username} liked your post",
          url: "/timeline/post/#{message_id}",
          source_type: "message",
          source_id: message_id,
          priority: "low"
        })
      end
    end
  end
end
