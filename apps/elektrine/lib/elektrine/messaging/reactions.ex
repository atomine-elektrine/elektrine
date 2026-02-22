defmodule Elektrine.Messaging.Reactions do
  @moduledoc "Context for managing message reactions.\n"
  import Ecto.Query, warn: false
  alias Elektrine.Messaging.{MessageReaction, RateLimiter}
  alias Elektrine.Repo
  @doc "Adds a reaction to a message.\n"
  def add_reaction(message_id, user_id, emoji) do
    if RateLimiter.can_add_reaction?(user_id) do
      MessageReaction.add_reaction_changeset(message_id, user_id, emoji)
      |> Repo.insert()
      |> case do
        {:ok, reaction} ->
          RateLimiter.record_reaction(user_id)
          broadcast_reaction_add(reaction)
          Task.start(fn -> notify_post_owner_of_reaction(reaction) end)
          Task.start(fn -> federate_emoji_reaction(reaction) end)
          {:ok, reaction}

        {:error, %{errors: [emoji: {_, constraint: :unique, constraint_name: _}]}} ->
          remove_reaction(message_id, user_id, emoji)

        error ->
          error
      end
    else
      {:error, :rate_limited}
    end
  end

  @doc "Removes a reaction from a message.\n"
  def remove_reaction(message_id, user_id, emoji) do
    case Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id, emoji: emoji) do
      nil ->
        {:error, :not_found}

      reaction ->
        case Repo.delete(reaction) do
          {:ok, deleted_reaction} ->
            broadcast_reaction_remove(deleted_reaction)
            Task.start(fn -> unfederate_emoji_reaction(deleted_reaction, user_id, emoji) end)
            {:ok, deleted_reaction}

          error ->
            error
        end
    end
  end

  defp broadcast_reaction_add(reaction) do
    reaction = Repo.preload(reaction, [:message, :user, :remote_actor])

    if reaction.message.conversation_id do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{reaction.message.conversation_id}",
        {:reaction_added, reaction}
      )
    end

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "post:#{reaction.message_id}",
      {:post_reaction_added, reaction}
    )

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "timeline:public",
      {:post_reaction_added, reaction}
    )
  end

  defp broadcast_reaction_remove(reaction) do
    reaction = Repo.preload(reaction, [:message, :user, :remote_actor])

    if reaction.message.conversation_id do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{reaction.message.conversation_id}",
        {:reaction_removed, reaction}
      )
    end

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "post:#{reaction.message_id}",
      {:post_reaction_removed, reaction}
    )

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

    if message && message.sender_id && reactor do
      source_type =
        cond do
          message.conversation_id -> "post"
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
    reaction = Repo.preload(reaction, [:message, :user])
    message = reaction.message

    if message.federated && message.activitypub_id && reaction.user do
      user = reaction.user

      emoji_react =
        Elektrine.ActivityPub.Builder.build_emoji_react_activity(
          user,
          message.activitypub_id,
          reaction.emoji
        )

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
    message = Elektrine.Messaging.get_message(reaction.message_id)

    if message && message.federated && message.activitypub_id do
      user = Elektrine.Accounts.get_user!(user_id)

      original_react = %{
        "type" => "EmojiReact",
        "actor" => "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}",
        "object" => message.activitypub_id,
        "content" => emoji
      }

      undo_activity = Elektrine.ActivityPub.Builder.build_undo_activity(user, original_react)

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
