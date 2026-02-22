defmodule Elektrine.PubSubTopics do
  @moduledoc """
  Centralized PubSub topic naming and management.
  Provides consistent topic names and subscription helpers across the application.
  """

  @doc """
  Topic for a user's personal timeline updates (posts from followed users).
  """
  def user_timeline(user_id), do: "user:#{user_id}:timeline"

  @doc """
  Topic for a user's profile updates (display name, avatar, bio changes).
  """
  def user_profile(user_id), do: "user:#{user_id}:profile"

  @doc """
  Topic for a user's follow updates (new followers, following changes).
  """
  def user_follows(user_id), do: "user:#{user_id}:follows"

  @doc """
  Topic for a user's notification updates.
  """
  def user_notifications(user_id), do: "user:#{user_id}:notifications"

  @doc """
  Topic for a specific conversation's messages.
  """
  def conversation(conversation_id), do: "chat:#{conversation_id}"

  @doc """
  Topic for conversation member updates (joins, leaves, role changes).
  """
  def conversation_members(conversation_id), do: "conversation:#{conversation_id}:members"

  @doc """
  Topic for public timeline (all public posts).
  """
  def timeline_public, do: "timeline:public"

  @doc """
  Topic for all timeline activity (for live updates).
  """
  def timeline_all, do: "timeline:all"

  @doc """
  Topic for local timeline (posts from this instance only).
  """
  def timeline_local, do: "timeline:local"

  @doc """
  Topic for presence tracking in a conversation.
  """
  def presence(conversation_id), do: "presence:chat:#{conversation_id}"

  @doc """
  Topic for a specific discussion/community.
  """
  def discussion(conversation_id), do: "discussion:#{conversation_id}"

  @doc """
  Topic for discussion post updates.
  """
  def discussion_post(message_id), do: "discussion:post:#{message_id}"

  @doc """
  Topic for moderation actions in a community.
  """
  def moderation(conversation_id), do: "moderation:#{conversation_id}"

  @doc """
  Topic for call events.
  """
  def call(call_id), do: "call:#{call_id}"

  @doc """
  Topic for user online status updates.
  """
  def user_status(user_id), do: "user:#{user_id}:status"

  @doc """
  Topic for global announcements.
  """
  def announcements, do: "announcements:all"

  @doc """
  Helper to broadcast to a topic.
  """
  def broadcast(topic, event, payload) do
    Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {event, payload})
  end

  @doc """
  Helper to subscribe to a topic.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(Elektrine.PubSub, topic)
  end

  @doc """
  Helper to subscribe to multiple topics.
  """
  def subscribe_all(topics) when is_list(topics) do
    Enum.each(topics, &subscribe/1)
  end

  @doc """
  Helper to unsubscribe from a topic.
  """
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(Elektrine.PubSub, topic)
  end

  @doc """
  Topic for a user's email updates (new emails, status changes).
  """
  def user_email(user_id), do: "user:#{user_id}:email"

  @doc """
  Topic for a user's VPN updates (config lifecycle and connection changes).
  """
  def user_vpn(user_id), do: "user:#{user_id}:vpn"

  @doc """
  Topic for the unified per-user event stream consumed by clients.
  """
  def user_events(user_id), do: "user:#{user_id}:events"

  @doc """
  Topic for mailbox-specific updates.
  """
  def mailbox(mailbox_id), do: "mailbox:#{mailbox_id}"
end
