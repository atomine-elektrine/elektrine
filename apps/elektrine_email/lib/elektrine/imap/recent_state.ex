defmodule Elektrine.IMAP.RecentState do
  @moduledoc false

  alias Elektrine.IMAP.{Folders, Helpers, RecentTracker}

  def merge_recent_message_ids(state, fresh_messages) do
    recent_message_ids = Map.get(state, :recent_message_ids, MapSet.new())

    folder_key =
      Map.get(state, :folder_key) || folder_key_for_mailbox(state.mailbox, state.selected_folder)

    recent_message_ids
    |> MapSet.union(claim_recent_message_ids(state.mailbox, folder_key, fresh_messages))
    |> trim_recent_message_ids(fresh_messages)
  end

  def trim_recent_message_ids(recent_message_ids, fresh_messages)
      when is_struct(recent_message_ids, MapSet) and is_list(fresh_messages) do
    active_message_ids = MapSet.new(fresh_messages, & &1.id)
    MapSet.intersection(recent_message_ids, active_message_ids)
  end

  def trim_recent_message_ids(fresh_messages, recent_message_ids)
      when is_list(fresh_messages) and is_struct(recent_message_ids, MapSet) do
    trim_recent_message_ids(recent_message_ids, fresh_messages)
  end

  def count_recent_messages(fresh_messages, recent_message_ids) do
    recent_message_ids
    |> trim_recent_message_ids(fresh_messages)
    |> MapSet.size()
  end

  def status_recent_count(messages, state, folder) do
    if state.state == :selected and
         state.selected_folder == Helpers.canonical_system_folder_name(folder) do
      count_recent_messages(messages, Map.get(state, :recent_message_ids, MapSet.new()))
    else
      count_global_recent_messages(state.mailbox, folder, messages)
    end
  end

  def claim_recent_message_ids(nil, _folder_key, _messages), do: MapSet.new()
  def claim_recent_message_ids(_mailbox, nil, _messages), do: MapSet.new()

  def claim_recent_message_ids(mailbox, folder_key, messages) do
    RecentTracker.claim_recent_message_ids(mailbox.id, folder_key, messages)
  end

  def count_global_recent_messages(nil, _folder, _messages), do: 0

  def count_global_recent_messages(mailbox, folder, messages) do
    RecentTracker.count_recent_message_ids(
      mailbox.id,
      folder_key_for_mailbox(mailbox, folder),
      messages
    )
  end

  def folder_key_for_mailbox(nil, _folder), do: nil

  def folder_key_for_mailbox(mailbox, folder) do
    canonical_folder = Helpers.canonical_system_folder_name(folder)

    case String.upcase(canonical_folder) do
      folder_name when folder_name in ["INBOX", "SENT", "DRAFTS", "TRASH", "SPAM"] ->
        folder_name

      _ ->
        case Folders.find_custom_folder_by_name(mailbox.user_id, canonical_folder) do
          %{id: folder_id} -> {:custom, folder_id}
          nil -> nil
        end
    end
  end

  def should_notify_idle_folder_update?(message, selected_folder) do
    if Folders.system_folder_name?(selected_folder || "") do
      Helpers.message_in_current_folder?(message, selected_folder)
    else
      true
    end
  end
end
