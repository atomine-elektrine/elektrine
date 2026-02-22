defmodule Elektrine.Notifications.FederationNotifications do
  @moduledoc """
  Handles notifications for ActivityPub federation events.
  """

  alias Elektrine.ActivityPub
  alias Elektrine.Notifications

  @doc """
  Notifies a user when a remote user follows them.
  """
  def notify_remote_follow(followed_user_id, remote_actor_id) do
    actor = Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id)

    if actor do
      Notifications.create_notification(%{
        user_id: followed_user_id,
        type: "follow",
        title: "New follower from the fediverse",
        body: "@#{actor.username}@#{actor.domain} is now following you",
        priority: "normal"
      })
    end
  end

  @doc """
  Notifies a user when their follow request is accepted.
  """
  def notify_follow_accepted(user_id, remote_actor_uri) do
    case ActivityPub.get_actor_by_uri(remote_actor_uri) do
      nil ->
        :ok

      actor ->
        Notifications.create_notification(%{
          user_id: user_id,
          type: "follow",
          title: "Follow request accepted",
          body: "@#{actor.username}@#{actor.domain} accepted your follow request",
          priority: "normal"
        })
    end
  end

  @doc """
  Notifies a user when a remote user likes their post.
  """
  def notify_remote_like(message_id, remote_actor_id) do
    message = Elektrine.Messaging.get_message(message_id)
    actor = Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id)

    if message && message.sender_id && actor do
      Notifications.create_notification(%{
        user_id: message.sender_id,
        type: "like",
        title: "Like from the fediverse",
        body: "@#{actor.username}@#{actor.domain} liked your post",
        url: "/timeline/post/#{message_id}",
        source_type: "message",
        source_id: message_id,
        priority: "low"
      })
    end
  end

  @doc """
  Notifies a user when a remote user reacts to their post with an emoji.
  """
  def notify_remote_reaction(message_id, remote_actor_id, emoji) do
    message = Elektrine.Messaging.get_message(message_id)
    actor = Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id)

    if message && message.sender_id && actor do
      Notifications.create_notification(%{
        user_id: message.sender_id,
        type: "reaction",
        title: "Reaction from the fediverse",
        body: "@#{actor.username}@#{actor.domain} reacted #{emoji} to your post",
        url: "/timeline/post/#{message_id}",
        source_type: "message",
        source_id: message_id,
        priority: "low"
      })
    end
  end

  @doc """
  Notifies a user when a remote user boosts/announces their post.
  """
  def notify_remote_announce(message_id, remote_actor_id) do
    message = Elektrine.Messaging.get_message(message_id)
    actor = Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id)

    if message && message.sender_id && actor do
      Notifications.create_notification(%{
        user_id: message.sender_id,
        type: "boost",
        title: "Boost from the fediverse",
        body: "@#{actor.username}@#{actor.domain} boosted your post",
        url: "/timeline/post/#{message_id}",
        source_type: "message",
        source_id: message_id,
        priority: "normal"
      })
    end
  end

  @doc """
  Notifies a user when a remote user replies to their post.
  """
  def notify_remote_reply(message_id, remote_actor_id) do
    message = Elektrine.Messaging.get_message(message_id)

    parent =
      if message.reply_to_id, do: Elektrine.Messaging.get_message(message.reply_to_id), else: nil

    actor = Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id)

    if parent && parent.sender_id && actor do
      Notifications.create_notification(%{
        user_id: parent.sender_id,
        type: "reply",
        title: "Reply from the fediverse",
        body: "@#{actor.username}@#{actor.domain} replied to your post",
        url: "/timeline/post/#{message_id}",
        source_type: "message",
        source_id: message_id,
        priority: "normal"
      })
    end
  end

  @doc """
  Notifies a user when a remote user mentions them in a post.
  """
  def notify_remote_mention(user_id, message_id, remote_actor_id) do
    actor = Elektrine.Repo.get(ActivityPub.Actor, remote_actor_id)

    if actor do
      Notifications.create_notification(%{
        user_id: user_id,
        type: "mention",
        title: "Mentioned in a post",
        body: "@#{actor.username}@#{actor.domain} mentioned you in a post",
        url: "/timeline/post/#{message_id}",
        source_type: "message",
        source_id: message_id,
        priority: "normal"
      })
    end
  end
end
