defmodule Elektrine.Messaging.Federation.DirectMessages do
  @moduledoc false

  def apply_event("dm.message.create", data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = dm_payload <- data["dm"],
         %{} = message_payload <- data["message"],
         {:ok, recipient_user} <-
           call(context, :resolve_local_dm_recipient, [dm_payload["recipient"]]),
         {:ok, remote_sender} <-
           call(context, :resolve_remote_dm_sender, [dm_payload["sender"], remote_domain]),
         {:ok, conversation} <-
           call(context, :ensure_remote_dm_conversation, [recipient_user, remote_sender]),
         {:ok, message_or_duplicate} <-
           call(context, :upsert_remote_dm_message, [
             conversation,
             message_payload,
             remote_domain,
             remote_sender
           ]),
         :ok <-
           call(context, :maybe_broadcast_remote_dm_message_created, [
             conversation,
             message_or_duplicate,
             recipient_user,
             remote_sender
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  def apply_event("dm.call.invite", data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = dm_payload <- data["dm"],
         %{} = call_payload <- data["call"],
         {:ok, recipient_user} <-
           call(context, :resolve_local_dm_recipient, [dm_payload["recipient"]]),
         {:ok, remote_sender} <-
           call(context, :resolve_remote_dm_sender, [dm_payload["sender"], remote_domain]),
         {:ok, conversation} <-
           call(context, :ensure_remote_dm_conversation, [recipient_user, remote_sender]),
         {:ok, _session} <-
           call(context, :ensure_inbound_call_session, [
             recipient_user,
             conversation,
             remote_sender,
             call_payload,
             remote_domain
           ]) do
      :ok
    else
      {:error, :busy} ->
        with %{} = dm_payload <- data["dm"],
             %{} = call_payload <- data["call"],
             {:ok, recipient_user} <-
               call(context, :resolve_local_dm_recipient, [dm_payload["recipient"]]),
             {:ok, remote_sender} <-
               call(context, :resolve_remote_dm_sender, [dm_payload["sender"], remote_domain]),
             {:ok, conversation} <-
               call(context, :ensure_remote_dm_conversation, [recipient_user, remote_sender]),
             {:ok, _session} <-
               call(context, :reject_inbound_call_invite, [
                 recipient_user,
                 conversation,
                 remote_sender,
                 call_payload,
                 remote_domain,
                 "busy"
               ]) do
          :ok
        else
          error -> normalize_event_error(error)
        end

      error -> normalize_event_error(error)
    end
  end

  def apply_event("dm.call.accept", data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = dm_payload <- data["dm"],
         call_id when is_binary(call_id) <- data["call_id"],
         %{} = actor_payload <- data["actor"],
         :ok <-
           call(context, :apply_remote_call_accept, [
             dm_payload,
             call_id,
             actor_payload,
             data["accepted_at"],
             remote_domain
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  def apply_event("dm.call.reject", data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = dm_payload <- data["dm"],
         call_id when is_binary(call_id) <- data["call_id"],
         %{} = actor_payload <- data["actor"],
         :ok <-
           call(context, :apply_remote_call_reject, [
             dm_payload,
             call_id,
             actor_payload,
             data["rejected_at"],
             data["reason"],
             remote_domain
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  def apply_event("dm.call.end", data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = dm_payload <- data["dm"],
         call_id when is_binary(call_id) <- data["call_id"],
         %{} = actor_payload <- data["actor"],
         :ok <-
           call(context, :apply_remote_call_end, [
             dm_payload,
             call_id,
             actor_payload,
             data["ended_at"],
             data["reason"],
             remote_domain
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  def apply_event("dm.call.signal", data, remote_domain, context)
      when is_map(data) and is_binary(remote_domain) and is_map(context) do
    with %{} = dm_payload <- data["dm"],
         call_id when is_binary(call_id) <- data["call_id"],
         %{} = actor_payload <- data["actor"],
         %{} = signal <- data["signal"],
         :ok <-
           call(context, :apply_remote_call_signal, [
             dm_payload,
             call_id,
             actor_payload,
             signal,
             remote_domain
           ]) do
      :ok
    else
      error -> normalize_event_error(error)
    end
  end

  def apply_event(_event_type, _data, _remote_domain, _context),
    do: {:error, :unhandled_event_type}

  defp normalize_event_error({:error, _reason} = error), do: error
  defp normalize_event_error(:ok), do: :ok
  defp normalize_event_error(_error), do: {:error, :invalid_event_payload}

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
