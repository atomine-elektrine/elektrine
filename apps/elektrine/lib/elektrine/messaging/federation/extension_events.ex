defmodule Elektrine.Messaging.Federation.ExtensionEvents do
  @moduledoc false

  def apply_event(event_type, data, remote_domain, context)
      when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and is_map(context) do
    case event_type do
      "role.upsert" -> apply_role_upsert(data, remote_domain, context)
      "role.assignment.upsert" -> apply_role_assignment_upsert(data, remote_domain, context)
      "permission.overwrite.upsert" -> apply_permission_overwrite_upsert(data, remote_domain, context)
      "thread.upsert" -> apply_thread_upsert(data, remote_domain, context)
      "thread.archive" -> apply_thread_archive(data, remote_domain, context)
      "moderation.action.recorded" -> apply_moderation_action_recorded(data, remote_domain, context)
      _ -> {:error, :unhandled_event_type}
    end
  end

  defp apply_role_upsert(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = role_payload <- data["role"],
         role_id when is_binary(role_id) <- role_payload["id"],
         role_name when is_binary(role_name) <- role_payload["name"],
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, mirror_channel} <-
           call(context, :upsert_single_mirror_channel, [mirror_server, channel_payload]),
         event_key <- "role:#{role_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           call(context, :upsert_extension_projection, [
             "role.upsert",
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             call(context, :parse_datetime, [role_payload["updated_at"]]) || DateTime.utc_now(),
             nil
           ]),
         :ok <-
           call(context, :upsert_extension_system_message, [
             mirror_channel,
             "role.upsert",
             event_key,
             "Role updated: #{role_name}",
             %{"event_type" => "role.upsert", "role" => role_payload},
             remote_domain
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_role_assignment_upsert(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = assignment_payload <- data["assignment"],
         role_id when is_binary(role_id) <- assignment_payload["role_id"],
         %{} = target <- assignment_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         state when is_binary(state) <- assignment_payload["state"],
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, mirror_channel} <-
           call(context, :upsert_single_mirror_channel, [mirror_server, channel_payload]),
         event_key <- "role_assignment:#{role_id}:#{target_type}:#{target_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           call(context, :upsert_extension_projection, [
             "role.assignment.upsert",
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             DateTime.utc_now(),
             nil
           ]),
         :ok <-
           call(context, :upsert_extension_system_message, [
             mirror_channel,
             "role.assignment.upsert",
             event_key,
             "Role #{state}: #{role_id} -> #{target_type}:#{target_id}",
             %{"event_type" => "role.assignment.upsert", "assignment" => assignment_payload},
             remote_domain
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_permission_overwrite_upsert(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = overwrite_payload <- data["overwrite"],
         overwrite_id when is_binary(overwrite_id) <- overwrite_payload["id"],
         %{} = target <- overwrite_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, mirror_channel} <-
           call(context, :upsert_single_mirror_channel, [mirror_server, channel_payload]),
         event_key <- "overwrite:#{overwrite_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           call(context, :upsert_extension_projection, [
             "permission.overwrite.upsert",
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             DateTime.utc_now(),
             nil
           ]),
         :ok <-
           call(context, :upsert_extension_system_message, [
             mirror_channel,
             "permission.overwrite.upsert",
             event_key,
             "Permissions updated for #{target_type}:#{target_id}",
             %{
               "event_type" => "permission.overwrite.upsert",
               "overwrite" => overwrite_payload
             },
             remote_domain
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_thread_upsert(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = thread_payload <- data["thread"],
         thread_id when is_binary(thread_id) <- thread_payload["id"],
         thread_name when is_binary(thread_name) <- thread_payload["name"],
         thread_state when is_binary(thread_state) <- thread_payload["state"],
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, mirror_channel} <-
           call(context, :upsert_single_mirror_channel, [mirror_server, channel_payload]),
         event_key <- "thread:#{thread_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           call(context, :upsert_extension_projection, [
             "thread.upsert",
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             DateTime.utc_now(),
             thread_state
           ]),
         :ok <-
           call(context, :upsert_extension_system_message, [
             mirror_channel,
             "thread.upsert",
             event_key,
             "Thread #{thread_state}: #{thread_name}",
             %{"event_type" => "thread.upsert", "thread" => thread_payload},
             remote_domain
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_thread_archive(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         thread_id when is_binary(thread_id) <- data["thread_id"],
         archived_at <- call(context, :parse_datetime, [data["archived_at"]]) || DateTime.utc_now(),
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, mirror_channel} <-
           call(context, :upsert_single_mirror_channel, [mirror_server, channel_payload]),
         event_key <- "thread:#{thread_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           call(context, :upsert_extension_projection, [
             "thread.archive",
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             archived_at,
             "archived"
           ]),
         :ok <-
           call(context, :upsert_extension_system_message, [
             mirror_channel,
             "thread.archive",
             event_key,
             "Thread archived: #{thread_id}",
             %{
               "event_type" => "thread.archive",
               "thread_id" => thread_id,
               "archived_at" => DateTime.to_iso8601(archived_at),
               "reason" => data["reason"]
             },
             remote_domain
           ]) do
      :ok
    else
      {:error, :federation_origin_conflict} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  defp apply_moderation_action_recorded(data, remote_domain, context) do
    with %{} = server_payload <- data["server"],
         %{} = channel_payload <- data["channel"],
         %{} = action_payload <- data["action"],
         action_id when is_binary(action_id) <- action_payload["id"],
         action_kind when is_binary(action_kind) <- action_payload["kind"],
         target when is_map(target) <- action_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         occurred_at <- call(context, :parse_datetime, [action_payload["occurred_at"]]) || DateTime.utc_now(),
         {:ok, mirror_server} <- call(context, :upsert_mirror_server, [server_payload, remote_domain]),
         {:ok, mirror_channel} <-
           call(context, :upsert_single_mirror_channel, [mirror_server, channel_payload]),
         event_key <- "moderation:#{action_id}:channel:#{mirror_channel.id}",
         {:ok, _event_projection} <-
           call(context, :upsert_extension_projection, [
             "moderation.action.recorded",
             event_key,
             data,
             remote_domain,
             mirror_server.id,
             mirror_channel.id,
             occurred_at,
             action_kind
           ]),
         :ok <-
           call(context, :upsert_extension_system_message, [
             mirror_channel,
             "moderation.action.recorded",
             event_key,
             "Moderation action (#{action_kind}) on #{target_type}:#{target_id}",
             %{
               "event_type" => "moderation.action.recorded",
               "action" => action_payload
             },
             remote_domain
           ]) do
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
