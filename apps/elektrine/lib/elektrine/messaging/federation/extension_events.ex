defmodule Elektrine.Messaging.Federation.ExtensionEvents do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.FederationExtensionEvent
  alias Elektrine.Repo

  def apply_event(event_type, data, remote_domain, context)
      when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and is_map(context) do
    case event_type do
      "role.upsert" ->
        apply_role_upsert(data, remote_domain, context)

      "role.assignment.upsert" ->
        apply_role_assignment_upsert(data, remote_domain, context)

      "permission.overwrite.upsert" ->
        apply_permission_overwrite_upsert(data, remote_domain, context)

      "thread.upsert" ->
        apply_thread_upsert(data, remote_domain, context)

      "thread.archive" ->
        apply_thread_archive(data, remote_domain, context)

      "moderation.action.recorded" ->
        apply_moderation_action_recorded(data, remote_domain, context)

      _ ->
        {:error, :unhandled_event_type}
    end
  end

  defp apply_role_upsert(data, remote_domain, context) do
    with %{} <- data["server"],
         %{} <- data["channel"],
         %{} = actor_payload <- data["actor"],
         %{} = role_payload <- data["role"],
         role_id when is_binary(role_id) <- role_payload["id"],
         role_name when is_binary(role_name) <- role_payload["name"],
         {:ok, mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :role_upsert,
             %{remote_actor_id: remote_actor_id},
             context
           ),
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
      error -> normalize_event_error(error)
    end
  end

  defp apply_role_assignment_upsert(data, remote_domain, context) do
    with %{} <- data["server"],
         %{} <- data["channel"],
         %{} = actor_payload <- data["actor"],
         %{} = assignment_payload <- data["assignment"],
         role_id when is_binary(role_id) <- assignment_payload["role_id"],
         %{} = target <- assignment_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         state when is_binary(state) <- assignment_payload["state"],
         {:ok, mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :role_assignment,
             %{remote_actor_id: remote_actor_id},
             context
           ),
         event_key <-
           "role_assignment:#{role_id}:#{target_type}:#{target_id}:channel:#{mirror_channel.id}",
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
      error -> normalize_event_error(error)
    end
  end

  defp apply_permission_overwrite_upsert(data, remote_domain, context) do
    with %{} <- data["server"],
         %{} <- data["channel"],
         %{} = actor_payload <- data["actor"],
         %{} = overwrite_payload <- data["overwrite"],
         overwrite_id when is_binary(overwrite_id) <- overwrite_payload["id"],
         %{} = target <- overwrite_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         {:ok, mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :permission_overwrite,
             %{remote_actor_id: remote_actor_id},
             context
           ),
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
      error -> normalize_event_error(error)
    end
  end

  defp apply_thread_upsert(data, remote_domain, context) do
    with %{} <- data["server"],
         %{} <- data["channel"],
         %{} = thread_payload <- data["thread"],
         thread_id when is_binary(thread_id) <- thread_payload["id"],
         thread_name when is_binary(thread_name) <- thread_payload["name"],
         thread_state when is_binary(thread_state) <- thread_payload["state"],
         %{} = owner_payload <- thread_payload["owner"],
         {:ok, mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [owner_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :thread_upsert,
             %{remote_actor_id: remote_actor_id, owner_remote_actor_id: remote_actor_id},
             context
           ),
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
      error -> normalize_event_error(error)
    end
  end

  defp apply_thread_archive(data, remote_domain, context) do
    with %{} <- data["server"],
         %{} <- data["channel"],
         thread_id when is_binary(thread_id) <- data["thread_id"],
         %{} = actor_payload <- data["actor"],
         archived_at <-
           call(context, :parse_datetime, [data["archived_at"]]) || DateTime.utc_now(),
         {:ok, mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         thread_owner_remote_actor_id <-
           resolve_thread_owner_remote_actor_id(
             mirror_channel.id,
             thread_id,
             remote_domain,
             context
           ),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :thread_archive,
             %{
               remote_actor_id: remote_actor_id,
               thread_owner_remote_actor_id: thread_owner_remote_actor_id
             },
             context
           ),
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
      error -> normalize_event_error(error)
    end
  end

  defp apply_moderation_action_recorded(data, remote_domain, context) do
    with %{} <- data["server"],
         %{} <- data["channel"],
         %{} = action_payload <- data["action"],
         action_id when is_binary(action_id) <- action_payload["id"],
         action_kind when is_binary(action_kind) <- action_payload["kind"],
         target when is_map(target) <- action_payload["target"],
         target_type when is_binary(target_type) <- target["type"],
         target_id when is_binary(target_id) <- target["id"],
         %{} = actor_payload <- action_payload["actor"],
         occurred_at <-
           call(context, :parse_datetime, [action_payload["occurred_at"]]) || DateTime.utc_now(),
         {:ok, mirror_server, mirror_channel} <-
           call(context, :resolve_channel_event_context, [data, remote_domain]),
         {:ok, remote_actor_id} <-
           call(context, :resolve_or_create_remote_actor_id, [actor_payload, remote_domain]),
         :ok <-
           authorize_governance_event(
             data,
             remote_domain,
             mirror_channel,
             remote_actor_id,
             :moderation_action,
             %{remote_actor_id: remote_actor_id, kind: action_kind},
             context
           ),
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
      error -> normalize_event_error(error)
    end
  end

  defp normalize_event_error({:error, _reason} = error), do: error
  defp normalize_event_error(:ok), do: :ok
  defp normalize_event_error(_error), do: {:error, :invalid_event_payload}

  defp authorize_governance_event(
         data,
         remote_domain,
         mirror_channel,
         remote_actor_id,
         action,
         options,
         context
       )
       when is_map(data) and is_binary(remote_domain) and is_map(mirror_channel) and
              is_integer(remote_actor_id) and is_atom(action) and is_map(options) and
              is_map(context) do
    case call(context, :ensure_authoritative_channel_event_context, [data, remote_domain]) do
      {:ok, _server, _channel} ->
        :ok

      _ ->
        call(context, :ensure_remote_actor_governance_permission, [
          mirror_channel,
          remote_actor_id,
          action,
          options
        ])
    end
  end

  defp authorize_governance_event(
         _data,
         _remote_domain,
         _mirror_channel,
         _remote_actor_id,
         _action,
         _options,
         _context
       ),
       do: {:error, :not_authorized_for_room}

  defp resolve_thread_owner_remote_actor_id(conversation_id, thread_id, remote_domain, context)
       when is_integer(conversation_id) and is_binary(thread_id) and is_binary(remote_domain) and
              is_map(context) do
    case thread_owner_actor_payload(conversation_id, thread_id) do
      %{} = owner_payload ->
        case call(context, :resolve_or_create_remote_actor_id, [owner_payload, remote_domain]) do
          {:ok, remote_actor_id} -> remote_actor_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_thread_owner_remote_actor_id(
         _conversation_id,
         _thread_id,
         _remote_domain,
         _context
       ),
       do: nil

  defp thread_owner_actor_payload(conversation_id, thread_id)
       when is_integer(conversation_id) and is_binary(thread_id) do
    event_type = Elektrine.Messaging.ArblargSDK.canonical_event_type("thread.upsert")
    event_key = "thread:#{thread_id}:channel:#{conversation_id}"

    from(event in FederationExtensionEvent,
      where:
        event.conversation_id == ^conversation_id and event.event_type == ^event_type and
          event.event_key == ^event_key,
      select: fragment("?->'thread'->'owner'", event.payload),
      limit: 1
    )
    |> Repo.one()
  end

  defp thread_owner_actor_payload(_conversation_id, _thread_id), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
