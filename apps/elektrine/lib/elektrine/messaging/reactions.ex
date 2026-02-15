defmodule Elektrine.Messaging.Reactions do
  @moduledoc """
  Context for managing message reactions.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Messaging.{MessageReaction, RateLimiter}

  @doc """
  Adds a reaction to a message.
  """
  def add_reaction(message_id, user_id, emoji) do
    # Check rate limiting first
    unless RateLimiter.can_add_reaction?(user_id) do
      {:error, :rate_limited}
    else
      MessageReaction.add_reaction_changeset(message_id, user_id, emoji)
      |> Repo.insert()
      |> case do
        {:ok, reaction} ->
          # Record for rate limiting
          RateLimiter.record_reaction(user_id)

          broadcast_reaction_add(reaction)

          # Send notification to post owner
          Task.start(fn ->
            notify_post_owner_of_reaction(reaction)
          end)

          # Federate emoji reaction if this is a federated post
          Task.start(fn ->
            federate_emoji_reaction(reaction)
          end)

          {:ok, reaction}

        {:error, %{errors: [emoji: {_, [constraint: :unique, constraint_name: _]}]}} ->
          # User already has this reaction, remove it instead
          remove_reaction(message_id, user_id, emoji)

        error ->
          error
      end
    end
  end

  @doc """
  Removes a reaction from a message.
  """
  def remove_reaction(message_id, user_id, emoji) do
    case Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id, emoji: emoji) do
      nil ->
        {:error, :not_found}

      reaction ->
        case Repo.delete(reaction) do
          {:ok, deleted_reaction} ->
            broadcast_reaction_remove(deleted_reaction)

            # Federate emoji reaction removal if this is a federated post
            Task.start(fn ->
              unfederate_emoji_reaction(deleted_reaction, user_id, emoji)
            end)

            {:ok, deleted_reaction}

          error ->
            error
        end
    end
  end

  ## Private Helpers

  defp broadcast_reaction_add(reaction) do
    reaction = Repo.preload(reaction, [:message, :user, :remote_actor])

    # Broadcast to conversation topic (for chat)
    if reaction.message.conversation_id do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{reaction.message.conversation_id}",
        {:reaction_added, reaction}
      )
    end

    # Broadcast to post topic (for timeline/posts)
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "post:#{reaction.message_id}",
      {:post_reaction_added, reaction}
    )

    # Also broadcast to public timeline for all viewers
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "timeline:public",
      {:post_reaction_added, reaction}
    )
  end

  defp broadcast_reaction_remove(reaction) do
    reaction = Repo.preload(reaction, [:message, :user, :remote_actor])

    # Broadcast to conversation topic (for chat)
    if reaction.message.conversation_id do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{reaction.message.conversation_id}",
        {:reaction_removed, reaction}
      )
    end

    # Broadcast to post topic (for timeline/posts)
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "post:#{reaction.message_id}",
      {:post_reaction_removed, reaction}
    )

    # Also broadcast to public timeline for all viewers
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "timeline:public",
      {:post_reaction_removed, reaction}
    )
  end

  defp notify_post_owner_of_reaction(reaction) do
    reaction = Repo.preload(reaction, [:message, :user])
    message = reaction.message
    reactor = reaction.user

    # Only notify for local posts with a sender (not federated posts)
    if message && message.sender_id && reactor do
      # Determine source type based on message type
      source_type =
        cond do
          # Discussion post
          message.conversation_id -> "post"
          # Timeline post
          message.federated -> "post"
          true -> "post"
        end

      Elektrine.Notifications.notify_reaction(
        message.sender_id,
        reactor,
        reaction.emoji,
        source_type,
        message.id
      )
    end
  end

  defp federate_emoji_reaction(reaction) do
    # Preload message and user
    reaction = Repo.preload(reaction, [:message, :user])
    message = reaction.message

    # Only federate if this is a reaction to a federated post
    if message.federated && message.activitypub_id && reaction.user do
      user = reaction.user

      # Build EmojiReact activity
      emoji_react =
        Elektrine.ActivityPub.Builder.build_emoji_react_activity(
          user,
          message.activitypub_id,
          reaction.emoji
        )

      # Get inbox of the post author
      if message.remote_actor_id do
        message = Repo.preload(message, :remote_actor)

        if message.remote_actor && message.remote_actor.inbox_url do
          Elektrine.ActivityPub.Publisher.publish(emoji_react, user, [
            message.remote_actor.inbox_url
          ])
        end
      end
    end
  end

  defp unfederate_emoji_reaction(reaction, user_id, emoji) do
    # Load the full message
    message = Elektrine.Messaging.get_message(reaction.message_id)

    # Only unfederate if this was a reaction to a federated post
    if message && message.federated && message.activitypub_id do
      user = Elektrine.Accounts.get_user!(user_id)

      # Build original EmojiReact activity
      original_react = %{
        "type" => "EmojiReact",
        "actor" => "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}",
        "object" => message.activitypub_id,
        "content" => emoji
      }

      # Build Undo activity
      undo_activity = Elektrine.ActivityPub.Builder.build_undo_activity(user, original_react)

      # Get inbox of the post author
      if message.remote_actor_id do
        message = Repo.preload(message, :remote_actor)

        if message.remote_actor && message.remote_actor.inbox_url do
          Elektrine.ActivityPub.Publisher.publish(undo_activity, user, [
            message.remote_actor.inbox_url
          ])
        end
      end
    end
  end
end
