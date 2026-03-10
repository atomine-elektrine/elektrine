defmodule Elektrine.Messaging.Federation.MirrorEvents do
  @moduledoc false

  def apply_event(event_type, data, remote_domain, context)
      when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and is_map(context) do
    case event_type do
      "server.upsert" -> apply_server_upsert(data, remote_domain, context)
      "message.create" -> apply_message_create(data, remote_domain, context)
      "message.update" -> apply_message_update(data, remote_domain, context)
      "message.delete" -> apply_message_delete(data, remote_domain, context)
      "reaction.add" -> apply_reaction_add(data, remote_domain, context)
      "reaction.remove" -> apply_reaction_remove(data, remote_domain, context)
      "read.cursor" -> apply_read_cursor(data, remote_domain, context)
      "invite.upsert" -> apply_invite_upsert(data, remote_domain, context)
      "ban.upsert" -> apply_ban_upsert(data, remote_domain, context)
      "membership.upsert" -> apply_membership_upsert(data, remote_domain, context)
      "presence.update" -> apply_presence_update(data, remote_domain, context)
      "typing.start" -> apply_typing_start(data, remote_domain, context)
      "typing.stop" -> apply_typing_stop(data, remote_domain, context)
      _ -> {:error, :unhandled_event_type}
    end
  end

  defp apply_server_upsert(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, _channel_map} <-
           call(context, :upsert_mirror_channels, [mirror_server, data["channels"] || []]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_message_create(data, remote_domain, context) do
    with %{} = message_payload <- data["message"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, mirror_message_or_duplicate} <-
           call(context, :upsert_mirror_message, [mirror_channel, message_payload, remote_domain]),
         :ok <-
           call(context, :maybe_broadcast_mirror_message_created, [mirror_message_or_duplicate]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_message_update(data, remote_domain, context) do
    with %{} = message_payload <- data["message"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, mirror_message} <-
           call(context, :upsert_or_update_mirror_message, [
             mirror_channel,
             message_payload,
             remote_domain
           ]),
         :ok <- call(context, :maybe_broadcast_mirror_message_updated, [mirror_message]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_message_delete(data, remote_domain, context) do
    with message_id when is_binary(message_id) <- data["message_id"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, deleted_message} <-
           call(context, :soft_delete_mirror_message, [
             mirror_channel,
             message_id,
             data["deleted_at"]
           ]),
         :ok <- call(context, :maybe_broadcast_mirror_message_deleted, [deleted_message.id]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_reaction_add(data, remote_domain, context) do
    with message_id when is_binary(message_id) <- data["message_id"],
         reaction when is_map(reaction) <- data["reaction"],
         emoji when is_binary(emoji) <- reaction["emoji"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, message} <- call(context, :get_mirror_message, [mirror_channel, message_id]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [reaction["actor"], remote_domain]),
         {:ok, reaction_or_duplicate} <-
           call(context, :add_mirror_reaction, [message.id, remote_actor_id, emoji]),
         :ok <-
           call(context, :maybe_broadcast_mirror_reaction_added, [
             message.id,
             reaction_or_duplicate
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_reaction_remove(data, remote_domain, context) do
    with message_id when is_binary(message_id) <- data["message_id"],
         reaction when is_map(reaction) <- data["reaction"],
         emoji when is_binary(emoji) <- reaction["emoji"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, message} <- call(context, :get_mirror_message, [mirror_channel, message_id]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [reaction["actor"], remote_domain]),
         {:ok, removed_count} <-
           call(context, :remove_mirror_reaction, [message.id, remote_actor_id, emoji]),
         :ok <-
           call(context, :maybe_broadcast_mirror_reaction_removed, [
             message.id,
             remote_actor_id,
             emoji,
             removed_count
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_read_cursor(data, remote_domain, context) do
    with read_through_message_id when is_binary(read_through_message_id) <- data["read_through_message_id"],
         %{} = actor_payload <- data["actor"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, message} <-
           call(context, :get_mirror_message, [mirror_channel, read_through_message_id]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         read_at <- call(context, :parse_datetime, [data["read_at"]]) || DateTime.utc_now(),
         read_through_sequence <- call(context, :parse_int, [data["read_through_sequence"], 0]),
         {:ok, _cursor} <-
           call(context, :upsert_remote_read_cursor, [
             mirror_channel.id,
             message.id,
             remote_actor_id,
             remote_domain,
             read_at,
             read_through_sequence
           ]),
         :ok <-
           call(context, :maybe_broadcast_remote_read_cursor, [
             mirror_channel.id,
             message.id,
             remote_actor_id
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_invite_upsert(data, remote_domain, context) do
    with %{} = invite_payload <- data["invite"],
         %{} = target_payload <- invite_payload["target"],
         %{} = actor_payload <- invite_payload["actor"],
         state when is_binary(state) <- invite_payload["state"],
         role when is_binary(role) <- invite_payload["role"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, remote_target_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [target_payload, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         {:ok, membership_state} <-
           call(context, :upsert_membership_state, [
             mirror_channel.id,
             remote_target_actor_id,
             remote_domain,
             role,
             call(context, :invite_membership_state, [state]),
             call(context, :parse_datetime, [invite_payload["invited_at"]]),
             call(context, :parse_datetime, [invite_payload["updated_at"]]) || DateTime.utc_now(),
             %{
               "governance_event" => "invite.upsert",
               "invite_state" => state,
               "actor" => actor_payload,
               "actor_remote_id" => remote_actor_id,
               "metadata" => invite_payload["metadata"] || %{}
             }
           ]),
         {:ok, _invite_state} <-
           call(context, :upsert_invite_state, [
             mirror_channel.id,
             remote_domain,
             actor_payload,
             target_payload,
             role,
             state,
             call(context, :parse_datetime, [invite_payload["invited_at"]]),
             call(context, :parse_datetime, [invite_payload["updated_at"]]) || DateTime.utc_now(),
             invite_payload["metadata"] || %{}
           ]),
         :ok <- call(context, :maybe_broadcast_membership_state, [mirror_channel.id, membership_state]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_ban_upsert(data, remote_domain, context) do
    with %{} = ban_payload <- data["ban"],
         %{} = target_payload <- ban_payload["target"],
         %{} = actor_payload <- ban_payload["actor"],
         state when is_binary(state) <- ban_payload["state"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, remote_target_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [target_payload, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         {:ok, membership_state} <-
           call(context, :upsert_membership_state, [
             mirror_channel.id,
             remote_target_actor_id,
             remote_domain,
             "member",
             call(context, :ban_membership_state, [state]),
             call(context, :parse_datetime, [ban_payload["banned_at"]]),
             call(context, :parse_datetime, [ban_payload["updated_at"]]) || DateTime.utc_now(),
             %{
               "governance_event" => "ban.upsert",
               "ban_state" => state,
               "reason" => ban_payload["reason"],
               "expires_at" => ban_payload["expires_at"],
               "actor" => actor_payload,
               "actor_remote_id" => remote_actor_id,
               "metadata" => ban_payload["metadata"] || %{}
             }
           ]),
         :ok <- call(context, :maybe_broadcast_membership_state, [mirror_channel.id, membership_state]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_membership_upsert(data, remote_domain, context) do
    with %{} = membership_payload <- data["membership"],
         %{} = actor_payload <- membership_payload["actor"],
         state when is_binary(state) <- membership_payload["state"],
         role when is_binary(role) <- membership_payload["role"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         {:ok, membership_state} <-
           call(context, :upsert_membership_state, [
             mirror_channel.id,
             remote_actor_id,
             remote_domain,
             role,
             state,
             call(context, :parse_datetime, [membership_payload["joined_at"]]),
             call(context, :parse_datetime, [membership_payload["updated_at"]]) || DateTime.utc_now(),
             membership_payload["metadata"] || %{}
           ]),
         :ok <- call(context, :maybe_broadcast_membership_state, [mirror_channel.id, membership_state]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_presence_update(data, remote_domain, context) do
    with %{} = _server_payload <- call(context, :event_server_payload, [data]),
         %{} = presence_payload <- data["presence"],
         %{} = actor_payload <- presence_payload["actor"],
         status when is_binary(status) <- presence_payload["status"],
         updated_at <- call(context, :parse_datetime, [presence_payload["updated_at"]]) || DateTime.utc_now(),
         {:ok, mirror_server} <- call(context, :ensure_server_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         activities <- call(context, :normalize_presence_activities, [presence_payload["activities"]]),
         {:ok, _presence_state} <-
           call(context, :upsert_presence_state, [
             mirror_server.id,
             remote_actor_id,
             status,
             activities,
             updated_at,
             remote_domain,
             call(context, :parse_int, [presence_payload["ttl_ms"], nil])
           ]),
         :ok <-
           call(context, :maybe_broadcast_presence_update, [
             mirror_server.id,
             remote_actor_id,
             status,
             activities,
             updated_at
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_typing_start(data, remote_domain, context) do
    with %{} = actor_payload <- data["actor"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <- call(context, :maybe_broadcast_remote_typing_started, [mirror_channel.id, remote_actor_id]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_typing_stop(data, remote_domain, context) do
    with %{} = actor_payload <- data["actor"],
         {:ok, _mirror_server, mirror_channel} <-
           call(context, :ensure_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <- call(context, :maybe_broadcast_remote_typing_stopped, [mirror_channel.id, remote_actor_id]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
