defmodule Elektrine.Messaging.Federation.Publisher do
  @moduledoc false

  alias Elektrine.Async
  alias Elektrine.Messaging.{ChatMessage, ChatMessageReaction}

  def push_server_snapshot(server_id, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, snapshot} <- call(context, :build_server_snapshot, [server_id]) do
        Enum.each(call(context, :outgoing_peers, []), fn peer ->
          call(context, :push_snapshot_to_peer, [peer, snapshot])
        end)
      end
    end

    :ok
  end

  def publish_server_upsert(server_id, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <- call(context, :build_server_upsert_event, [server_id]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def publish_message_created(%ChatMessage{} = message, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <- call(context, :build_message_created_event, [message]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def publish_message_created(message_id, context)
      when is_integer(message_id) and is_map(context) do
    case call(context, :get_chat_message, [message_id]) do
      nil -> :ok
      message -> publish_message_created(message, context)
    end
  end

  def publish_dm_message_created(%ChatMessage{} = message, remote_handle, context)
      when is_map(context) do
    if enabled?(context) do
      with {:ok, outbound_handle} <-
             call(context, :resolve_outbound_dm_handle, [message, remote_handle]),
           {:ok, recipient} <- call(context, :normalize_remote_dm_handle, [outbound_handle]),
           %{} <- call(context, :outgoing_peer, [recipient.domain]),
           {:ok, event} <- call(context, :build_dm_message_created_event, [message, recipient.handle]) do
        enqueue_outbox_event(context, event, [recipient.domain])
      end
    end

    :ok
  end

  def publish_message_updated(%ChatMessage{} = message, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <- call(context, :build_message_updated_event, [message]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def publish_message_updated(message_id, context)
      when is_integer(message_id) and is_map(context) do
    case call(context, :get_chat_message, [message_id]) do
      nil -> :ok
      message -> publish_message_updated(message, context)
    end
  end

  def publish_message_deleted(%ChatMessage{} = message, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <- call(context, :build_message_deleted_event, [message]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def publish_message_deleted(message_id, context)
      when is_integer(message_id) and is_map(context) do
    case call(context, :get_chat_message, [message_id]) do
      nil -> :ok
      message -> publish_message_deleted(message, context)
    end
  end

  def publish_reaction_added(%ChatMessage{} = message, %ChatMessageReaction{} = reaction, context)
      when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <- call(context, :build_reaction_added_event, [message, reaction]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def publish_reaction_removed(%ChatMessage{} = message, user_id, emoji, context)
      when is_integer(user_id) and is_map(context) do
    if enabled?(context) do
      with {:ok, event} <- call(context, :build_reaction_removed_event, [message, user_id, emoji]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def publish_read_cursor(conversation_id, user_id, message_id, read_at, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_integer(message_id) and
             is_map(context) do
    if enabled?(context) do
      with {:ok, event, target_domains} <-
             call(context, :build_read_cursor_event, [
               conversation_id,
               user_id,
               message_id,
               read_at
             ]) do
        enqueue_outbox_event(context, event, target_domains)
      end
    end

    :ok
  end

  def publish_read_receipt(conversation_id, user_id, message_id, read_at, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_integer(message_id) and
             is_map(context) do
    publish_read_cursor(conversation_id, user_id, message_id, read_at, context)
  end

  def publish_typing_started(conversation_id, user_id, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_map(context) do
    publish_typing_indicator(conversation_id, user_id, :start, context)
  end

  def publish_typing_stopped(conversation_id, user_id, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_map(context) do
    publish_typing_indicator(conversation_id, user_id, :stop, context)
  end

  def publish_presence_update(server_id, user_id, status, activities, context)
      when is_integer(server_id) and is_integer(user_id) and is_binary(status) and
             is_map(context) do
    if enabled?(context) do
      Async.start(fn ->
        with {:ok, item, target_domains} <-
               call(context, :build_presence_ephemeral_item, [
                 server_id,
                 user_id,
                 status,
                 activities
               ]) do
          _ = call(context, :fanout_ephemeral_batch, [[item], target_domains])
        end
      end)
    end

    :ok
  end

  def publish_user_presence_update(user_id, status, activities, context)
      when is_integer(user_id) and is_binary(status) and is_map(context) do
    if enabled?(context) do
      call(context, :active_server_ids_for_user, [user_id])
      |> Enum.each(fn server_id ->
        publish_presence_update(server_id, user_id, status, activities, context)
      end)
    end

    :ok
  end

  def publish_membership_state(conversation_id, user_id, state, role, context)
      when is_integer(conversation_id) and is_integer(user_id) and is_binary(state) and
             is_binary(role) and is_map(context) do
    if enabled?(context) do
      with {:ok, event, target_domains} <-
             call(context, :build_membership_upsert_event, [
               conversation_id,
               user_id,
               state,
               role
             ]) do
        enqueue_outbox_event(context, event, target_domains)
      end
    end

    :ok
  end

  def publish_invite_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        role,
        metadata,
        context
      )
      when is_integer(conversation_id) and is_integer(target_user_id) and
             is_integer(actor_user_id) and is_binary(state) and is_binary(role) and
             is_map(metadata) and is_map(context) do
    if enabled?(context) do
      with {:ok, event, target_domains} <-
             call(context, :build_invite_upsert_event, [
               conversation_id,
               target_user_id,
               actor_user_id,
               state,
               role,
               metadata
             ]),
           :ok <-
             call(context, :persist_local_invite_projection, [
               conversation_id,
               target_user_id,
               actor_user_id,
               state,
               role,
               metadata
             ]) do
        enqueue_outbox_event(context, event, target_domains)
      end
    end

    :ok
  end

  def publish_ban_state(
        conversation_id,
        target_user_id,
        actor_user_id,
        state,
        reason,
        expires_at,
        metadata,
        context
      )
      when is_integer(conversation_id) and is_integer(target_user_id) and
             is_integer(actor_user_id) and is_binary(state) and is_map(metadata) and
             is_map(context) do
    if enabled?(context) do
      with {:ok, event, target_domains} <-
             call(context, :build_ban_upsert_event, [
               conversation_id,
               target_user_id,
               actor_user_id,
               state,
               reason,
               expires_at,
               metadata
             ]) do
        enqueue_outbox_event(context, event, target_domains)
      end
    end

    :ok
  end

  def submit_mirror_message_created(%ChatMessage{} = message, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <-
             call(context, :build_message_created_event_with_opts, [
               message,
               [allow_mirror: true]
             ]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def submit_mirror_message_updated(%ChatMessage{} = message, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <-
             call(context, :build_message_updated_event_with_opts, [
               message,
               [allow_mirror: true]
             ]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def submit_mirror_message_deleted(%ChatMessage{} = message, context) when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <-
             call(context, :build_message_deleted_event_with_opts, [
               message,
               [allow_mirror: true]
             ]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def submit_mirror_reaction_added(
        %ChatMessage{} = message,
        %ChatMessageReaction{} = reaction,
        context
      )
      when is_map(context) do
    if enabled?(context) do
      with {:ok, event} <-
             call(context, :build_reaction_added_event_with_opts, [
               message,
               reaction,
               [allow_mirror: true]
             ]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def submit_mirror_reaction_removed(%ChatMessage{} = message, user_id, emoji, context)
      when is_integer(user_id) and is_map(context) do
    if enabled?(context) do
      with {:ok, event} <-
             call(context, :build_reaction_removed_event_with_opts, [
               message,
               user_id,
               emoji,
               [allow_mirror: true]
             ]) do
        enqueue_outbox_event(context, event)
      end
    end

    :ok
  end

  def maybe_push_for_conversation(conversation_id, context)
      when is_integer(conversation_id) and is_map(context) do
    if enabled?(context) do
      Async.start(fn -> call(context, :publish_latest_message_event, [conversation_id]) end)
    end

    :ok
  end

  def maybe_push_for_server(server_id, context)
      when is_integer(server_id) and is_map(context) do
    if enabled?(context) do
      Async.start(fn -> publish_server_upsert(server_id, context) end)
    end

    :ok
  end

  defp publish_typing_indicator(conversation_id, user_id, mode, context)
       when mode in [:start, :stop] and is_integer(conversation_id) and is_integer(user_id) do
    if enabled?(context) do
      Async.start(fn ->
        with {:ok, item, target_domains} <-
               call(context, :build_typing_ephemeral_item, [conversation_id, user_id, mode]) do
          _ = call(context, :fanout_ephemeral_batch, [[item], target_domains])
        end
      end)
    end

    :ok
  end

  defp enabled?(context) do
    call(context, :enabled?, [])
  end

  defp enqueue_outbox_event(context, event, target_domains \\ :all) do
    call(context, :enqueue_outbox_event, [event, target_domains])
  end

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
