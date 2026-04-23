defmodule Elektrine.IMAP.RecentTracker do
  @moduledoc false

  @table :imap_recent_messages
  @max_age_seconds 24 * 60 * 60

  def mark_message_recent(message) when is_map(message) do
    with mailbox_id when is_integer(mailbox_id) <- Map.get(message, :mailbox_id),
         {:ok, folder_key} <- folder_key_for_message(message),
         message_id when is_integer(message_id) <- Map.get(message, :id) do
      cleanup_stale_entries()

      :ets.insert_new(
        table(),
        {entry_key(mailbox_id, folder_key, message_id), System.system_time(:second)}
      )

      :ok
    else
      _ -> :ok
    end
  end

  def claim_recent_message_ids(mailbox_id, folder_key, messages)
      when is_integer(mailbox_id) and is_list(messages) do
    cleanup_stale_entries()

    messages
    |> Enum.reduce(MapSet.new(), fn message, recent_ids ->
      message_id = Map.get(message, :id)

      if is_integer(message_id) and
           :ets.take(table(), entry_key(mailbox_id, folder_key, message_id)) != [] do
        MapSet.put(recent_ids, message_id)
      else
        recent_ids
      end
    end)
  end

  def count_recent_message_ids(mailbox_id, folder_key, messages)
      when is_integer(mailbox_id) and is_list(messages) do
    cleanup_stale_entries()

    Enum.count(messages, fn message ->
      message_id = Map.get(message, :id)

      is_integer(message_id) and
        :ets.member(table(), entry_key(mailbox_id, folder_key, message_id))
    end)
  end

  def table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    @table
  rescue
    ArgumentError -> @table
  end

  defp folder_key_for_message(message) do
    cond do
      is_integer(Map.get(message, :folder_id)) ->
        {:ok, {:custom, Map.get(message, :folder_id)}}

      Map.get(message, :deleted, false) ->
        {:ok, "TRASH"}

      Map.get(message, :spam, false) and Map.get(message, :status) not in ["sent", "draft"] ->
        {:ok, "SPAM"}

      Map.get(message, :status) == "sent" ->
        {:ok, "SENT"}

      Map.get(message, :status) == "draft" ->
        {:ok, "DRAFTS"}

      !Map.get(message, :archived, false) ->
        {:ok, "INBOX"}

      true ->
        :error
    end
  end

  defp cleanup_stale_entries do
    now = System.system_time(:second)
    cutoff = now - @max_age_seconds

    table()
    |> :ets.select_delete([
      {{{:"$1", :"$2", :"$3"}, :"$4"}, [{:<, :"$4", cutoff}], [true]}
    ])

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp entry_key(mailbox_id, folder_key, message_id), do: {mailbox_id, folder_key, message_id}
end
