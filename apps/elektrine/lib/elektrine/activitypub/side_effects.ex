defmodule Elektrine.ActivityPub.SideEffects do
  @moduledoc """
  Handles side effects after ActivityPub activities are processed.

  Side effects include:
  - Sending notifications
  - Broadcasting to PubSub channels
  - Updating counters and statistics
  - Triggering background jobs

  This module is inspired by Akkoma's side_effects.ex pattern,
  separating the "what happened" from the "what should happen next".
  """

  require Logger

  alias Elektrine.Notifications.FederationNotifications

  @doc """
  Generic side effect handler called by the Pipeline.
  Dispatches to specific handlers based on activity type.
  Returns :ok always - side effects should not fail the main transaction.
  """
  def handle(activity, _actor_uri, _result) do
    # Side effects are best-effort and type-specific
    # The Pipeline calls this generically; we dispatch based on activity type
    case activity["type"] do
      "Like" ->
        # Like side effects are handled when the LikeHandler processes it
        :ok

      "Announce" ->
        # Announce side effects are handled when AnnounceHandler processes it
        :ok

      "Follow" ->
        # Follow side effects are handled when FollowHandler processes it
        :ok

      "Create" ->
        # Create side effects (like broadcasting) are handled in CreateHandler
        :ok

      _ ->
        # No side effects for this activity type
        :ok
    end
  end

  @doc """
  Triggers side effects for a Like activity.
  """
  def handle_like(message_id, remote_actor_id) do
    Task.start(fn ->
      FederationNotifications.notify_remote_like(message_id, remote_actor_id)
    end)

    :ok
  end

  @doc """
  Triggers side effects for an EmojiReact activity.
  """
  def handle_emoji_react(message_id, remote_actor_id, emoji) do
    Task.start(fn ->
      FederationNotifications.notify_remote_reaction(message_id, remote_actor_id, emoji)
    end)

    :ok
  end

  @doc """
  Triggers side effects for an Announce (boost) activity.
  """
  def handle_announce(message_id, remote_actor_id) do
    Task.start(fn ->
      FederationNotifications.notify_remote_announce(message_id, remote_actor_id)
    end)

    :ok
  end

  @doc """
  Triggers side effects for a Follow activity.
  """
  def handle_follow(followed_user_id, remote_actor_id) do
    Task.start(fn ->
      FederationNotifications.notify_remote_follow(followed_user_id, remote_actor_id)
    end)

    :ok
  end

  @doc """
  Triggers side effects for a Follow Accept activity.
  """
  def handle_follow_accepted(user_id, followed_actor_uri) do
    Task.start(fn ->
      FederationNotifications.notify_follow_accepted(user_id, followed_actor_uri)
    end)

    :ok
  end

  @doc """
  Triggers side effects for a reply to a local post.
  """
  def handle_reply(message_id, remote_actor_id) do
    Task.start(fn ->
      FederationNotifications.notify_remote_reply(message_id, remote_actor_id)
    end)

    :ok
  end

  @doc """
  Triggers side effects for a mention of a local user.
  """
  def handle_mention(user_id, message_id, remote_actor_id) do
    remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, remote_actor_id)

    actor_name =
      if remote_actor do
        "@#{remote_actor.username}@#{remote_actor.domain}"
      else
        "a remote user"
      end

    Elektrine.Notifications.create_notification(%{
      user_id: user_id,
      type: "mention",
      title: "Mentioned in a post",
      body: "#{actor_name} mentioned you in a post",
      source_type: "message",
      source_id: message_id,
      priority: "normal"
    })

    :ok
  end

  @doc """
  Broadcasts a new post to the public timeline.
  """
  def broadcast_new_post(message) do
    reloaded =
      Elektrine.Repo.preload(
        message,
        [:remote_actor, :sender, :link_preview, :hashtags],
        force: true
      )

    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "timeline:public",
      {:new_public_post, reloaded}
    )

    :ok
  end

  @doc """
  Increments the reply count on a parent message.
  """
  def increment_reply_count(parent_message_id) when not is_nil(parent_message_id) do
    Elektrine.Social.increment_reply_count(parent_message_id)
    :ok
  end

  def increment_reply_count(nil), do: :ok

  @doc """
  Updates engagement counts on a cached remote post.
  Called when we receive new interactions for posts we've cached.
  """
  def update_cached_post_counts(message_id, opts \\ []) do
    import Ecto.Query

    updates =
      Enum.reduce(opts, [], fn
        {:like_count, count}, acc -> [{:like_count, count} | acc]
        {:reply_count, count}, acc -> [{:reply_count, count} | acc]
        {:share_count, count}, acc -> [{:share_count, count} | acc]
        _, acc -> acc
      end)

    if updates != [] do
      Elektrine.Repo.update_all(
        from(m in Elektrine.Messaging.Message, where: m.id == ^message_id),
        set: updates
      )
    end

    :ok
  end
end
