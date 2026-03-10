defmodule Elektrine.Messaging.Federation.Egress do
  @moduledoc false

  alias Elektrine.Messaging.Federation.Contexts
  alias Elektrine.Messaging.Federation.Delivery
  alias Elektrine.Messaging.Federation.Ingress
  alias Elektrine.Messaging.Federation.PublicDiscovery
  alias Elektrine.Messaging.Federation.Publisher
  alias Elektrine.Messaging.Federation.RequestAuth
  alias Elektrine.Messaging.Federation.Runtime
  alias Elektrine.Messaging.Federation.Utils

  alias Elektrine.Messaging.{ChatMessage, ChatMessageReaction}
  alias Elektrine.Repo

  @successful_delivery_statuses MapSet.new([
                                  "applied",
                                  "duplicate",
                                  "stale",
                                  "recovered_via_stream",
                                  "recovered_via_snapshot"
                                ])

  def push_server_snapshot(server_id) do
    push_server_snapshot(server_id, publisher_context())
  end

  def push_server_snapshot(server_id, publisher_context) do
    Publisher.push_server_snapshot(server_id, publisher_context)
  end

  def publish_server_upsert(server_id) do
    publish_server_upsert(server_id, publisher_context())
  end

  def publish_server_upsert(server_id, publisher_context) do
    Publisher.publish_server_upsert(server_id, publisher_context)
  end

  def publish_message_created(message) do
    publish_message_created(message, publisher_context())
  end

  def publish_message_created(%ChatMessage{} = message, publisher_context) do
    Publisher.publish_message_created(message, publisher_context)
  end

  def publish_message_created(message_id, publisher_context) when is_integer(message_id) do
    Publisher.publish_message_created(message_id, publisher_context)
  end

  def publish_dm_message_created(message, remote_handle \\ nil)

  def publish_dm_message_created(%ChatMessage{} = message, remote_handle) do
    publish_dm_message_created(message, remote_handle, publisher_context())
  end

  def publish_dm_message_created(%ChatMessage{} = message, remote_handle, publisher_context) do
    Publisher.publish_dm_message_created(message, remote_handle, publisher_context)
  end

  def publish_message_updated(message) do
    publish_message_updated(message, publisher_context())
  end

  def publish_message_updated(%ChatMessage{} = message, publisher_context) do
    Publisher.publish_message_updated(message, publisher_context)
  end

  def publish_message_updated(message_id, publisher_context) when is_integer(message_id) do
    Publisher.publish_message_updated(message_id, publisher_context)
  end

  def publish_message_deleted(message) do
    publish_message_deleted(message, publisher_context())
  end

  def publish_message_deleted(%ChatMessage{} = message, publisher_context) do
    Publisher.publish_message_deleted(message, publisher_context)
  end

  def publish_message_deleted(message_id, publisher_context) when is_integer(message_id) do
    Publisher.publish_message_deleted(message_id, publisher_context)
  end

  def publish_reaction_added(message, reaction) do
    publish_reaction_added(message, reaction, publisher_context())
  end

  def publish_reaction_added(
        %ChatMessage{} = message,
        %ChatMessageReaction{} = reaction,
        publisher_context
      ) do
    Publisher.publish_reaction_added(message, reaction, publisher_context)
  end

  def publish_reaction_removed(%ChatMessage{} = message, user_id, emoji)
      when is_integer(user_id) do
    publish_reaction_removed(message, user_id, emoji, publisher_context())
  end

  def publish_reaction_removed(%ChatMessage{} = message, user_id, emoji, publisher_context)
      when is_integer(user_id) do
    Publisher.publish_reaction_removed(message, user_id, emoji, publisher_context)
  end

  def publish_read_cursor(conversation_id, user_id, message_id, read_at \\ DateTime.utc_now()) do
    publish_read_cursor(conversation_id, user_id, message_id, read_at, publisher_context())
  end

  def publish_read_cursor(conversation_id, user_id, message_id, read_at, publisher_context) do
    Publisher.publish_read_cursor(
      conversation_id,
      user_id,
      message_id,
      read_at,
      publisher_context
    )
  end

  def publish_read_receipt(conversation_id, user_id, message_id, read_at \\ DateTime.utc_now()) do
    publish_read_receipt(conversation_id, user_id, message_id, read_at, publisher_context())
  end

  def publish_read_receipt(conversation_id, user_id, message_id, read_at, publisher_context) do
    Publisher.publish_read_receipt(
      conversation_id,
      user_id,
      message_id,
      read_at,
      publisher_context
    )
  end

  def publish_typing_started(conversation_id, user_id) do
    publish_typing_started(conversation_id, user_id, publisher_context())
  end

  def publish_typing_started(conversation_id, user_id, publisher_context) do
    Publisher.publish_typing_started(conversation_id, user_id, publisher_context)
  end

  def publish_typing_stopped(conversation_id, user_id) do
    publish_typing_stopped(conversation_id, user_id, publisher_context())
  end

  def publish_typing_stopped(conversation_id, user_id, publisher_context) do
    Publisher.publish_typing_stopped(conversation_id, user_id, publisher_context)
  end

  def publish_presence_update(server_id, user_id, status, activities \\ []) do
    publish_presence_update(server_id, user_id, status, activities, publisher_context())
  end

  def publish_presence_update(server_id, user_id, status, activities, publisher_context) do
    Publisher.publish_presence_update(server_id, user_id, status, activities, publisher_context)
  end

  def publish_user_presence_update(user_id, status, activities \\ []) do
    publish_user_presence_update(user_id, status, activities, publisher_context())
  end

  def publish_user_presence_update(user_id, status, activities, publisher_context) do
    Publisher.publish_user_presence_update(user_id, status, activities, publisher_context)
  end

  def publish_membership_state(conversation_id, user_id, state, role \\ "member") do
    publish_membership_state(conversation_id, user_id, state, role, publisher_context())
  end

  def publish_membership_state(conversation_id, user_id, state, role, publisher_context) do
    Publisher.publish_membership_state(conversation_id, user_id, state, role, publisher_context)
  end

  def publish_invite_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state \\ "pending",
        role \\ "member",
        metadata \\ %{}
      ) do
    publish_invite_state(
      conversation_id,
      target_user_id,
      actor_user_id,
      state,
      role,
      metadata,
      publisher_context()
    )
  end

  def publish_invite_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        role,
        metadata,
        publisher_context
      ) do
    Publisher.publish_invite_state(
      conversation_id,
      target_user_id,
      actor_user_id,
      state,
      role,
      metadata,
      publisher_context
      )
  end

  def publish_ban_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state \\ "active",
        reason \\ nil,
        expires_at \\ nil,
        metadata \\ %{}
      ) do
    publish_ban_state(
      conversation_id,
      target_user_id,
      actor_user_id,
      state,
      reason,
      expires_at,
      metadata,
      publisher_context()
    )
  end

  def publish_ban_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        reason,
        expires_at,
        metadata,
        publisher_context
      ) do
    Publisher.publish_ban_state(
      conversation_id,
      target_user_id,
      actor_user_id,
      state,
      reason,
      expires_at,
      metadata,
      publisher_context
      )
  end

  def submit_mirror_message_created(message) do
    submit_mirror_message_created(message, publisher_context())
  end

  def submit_mirror_message_created(%ChatMessage{} = message, publisher_context) do
    Publisher.submit_mirror_message_created(message, publisher_context)
  end

  def submit_mirror_message_updated(message) do
    submit_mirror_message_updated(message, publisher_context())
  end

  def submit_mirror_message_updated(%ChatMessage{} = message, publisher_context) do
    Publisher.submit_mirror_message_updated(message, publisher_context)
  end

  def submit_mirror_message_deleted(message) do
    submit_mirror_message_deleted(message, publisher_context())
  end

  def submit_mirror_message_deleted(%ChatMessage{} = message, publisher_context) do
    Publisher.submit_mirror_message_deleted(message, publisher_context)
  end

  def submit_mirror_reaction_added(message, reaction) do
    submit_mirror_reaction_added(message, reaction, publisher_context())
  end

  def submit_mirror_reaction_added(
        %ChatMessage{} = message,
        %ChatMessageReaction{} = reaction,
        publisher_context
      ) do
    Publisher.submit_mirror_reaction_added(message, reaction, publisher_context)
  end

  def submit_mirror_reaction_removed(%ChatMessage{} = message, user_id, emoji)
      when is_integer(user_id) do
    submit_mirror_reaction_removed(message, user_id, emoji, publisher_context())
  end

  def submit_mirror_reaction_removed(%ChatMessage{} = message, user_id, emoji, publisher_context)
      when is_integer(user_id) do
    Publisher.submit_mirror_reaction_removed(message, user_id, emoji, publisher_context)
  end

  def maybe_push_for_conversation(conversation_id) do
    maybe_push_for_conversation(conversation_id, publisher_context())
  end

  def maybe_push_for_conversation(conversation_id, publisher_context) do
    Publisher.maybe_push_for_conversation(conversation_id, publisher_context)
  end

  def maybe_push_for_server(server_id) do
    maybe_push_for_server(server_id, publisher_context())
  end

  def maybe_push_for_server(server_id, publisher_context) do
    Publisher.maybe_push_for_server(server_id, publisher_context)
  end

  def process_outbox_event(outbox_event_id) when is_integer(outbox_event_id) do
    Delivery.process_outbox_event(outbox_event_id, delivery_context())
  end

  def enqueue_due_outbox_events(limit \\ 500) do
    Delivery.enqueue_due_outbox_events(limit, delivery_context())
  end

  defp publisher_context do
    Contexts.publisher(%{
      enabled?: &Runtime.enabled?/0,
      build_server_snapshot: &Ingress.build_server_snapshot/1,
      outgoing_peers: &Elektrine.Messaging.Federation.Peers.outgoing_peers/0,
      push_snapshot_to_peer: &Ingress.push_snapshot_to_peer/2,
      builder_context: &builder_context/0,
      dispatch_context: &dispatch_context/0,
      outgoing_peer: &Elektrine.Messaging.Federation.Peers.outgoing_peer/1,
      state_context: &state_context/0,
      mirror_broadcast_context: &mirror_broadcast_context/0,
      get_chat_message: fn message_id -> Repo.get(ChatMessage, message_id) end,
      publish_message_created: &publish_message_created/1
    })
  end

  defp builder_context do
    Contexts.builder(%{
      outgoing_peers: &Elektrine.Messaging.Federation.Peers.outgoing_peers/0,
      maybe_iso8601: &maybe_iso8601/1,
      normalize_optional_string: &normalize_optional_string/1
    })
  end

  defp delivery_context do
    Contexts.delivery(%{
      successful_delivery_statuses: @successful_delivery_statuses,
      outgoing_peer: &Elektrine.Messaging.Federation.Peers.outgoing_peer/1,
      transport_profiles_document: &PublicDiscovery.transport_profiles_document/0,
      signed_headers: &RequestAuth.signed_headers/5,
      truncate: &Utils.truncate/1,
      next_outbound_sequence: &Utils.next_outbound_sequence/1,
      normalize_optional_string: &normalize_optional_string/1,
      builder_context: &builder_context/0
    })
  end

  defp dispatch_context do
    Contexts.dispatch(%{
      outgoing_peers: &Elektrine.Messaging.Federation.Peers.outgoing_peers/0,
      outgoing_peer: &Elektrine.Messaging.Federation.Peers.outgoing_peer/1,
      delivery_context: &delivery_context/0
    })
  end

  defp state_context, do: Contexts.state()

  defp mirror_broadcast_context do
    Contexts.mirror_broadcast(%{
      publish_message_created: &publish_message_created/1
    })
  end

  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp maybe_iso8601(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp maybe_iso8601(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil
end
