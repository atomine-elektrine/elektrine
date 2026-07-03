defmodule Elektrine.IMAP.Commands.Mailbox do
  @moduledoc "IMAP mailbox and folder commands (SELECT, EXAMINE, LIST, LSUB, CREATE, DELETE, RENAME, SUBSCRIBE, STATUS, QUOTA)."

  alias Elektrine.IMAP.Commands.Shared
  alias Elektrine.IMAP.{Folders, Helpers, RecentState}

  @default_storage_limit_bytes 524_288_000

  def handle_select(tag, args, state) do
    with {:ok, folder} <- Helpers.parse_mailbox_arg(args),
         {:ok, messages} <- Shared.load_folder_messages(state.mailbox, folder) do
      canonical_folder = Helpers.canonical_system_folder_name(folder)
      folder_key = RecentState.folder_key_for_mailbox(state.mailbox, canonical_folder)

      recent_message_ids =
        RecentState.claim_recent_message_ids(state.mailbox, folder_key, messages)

      first_unseen = find_first_unseen(messages)
      Helpers.send_response(state.socket, "* #{length(messages)} EXISTS")
      Helpers.send_response(state.socket, "* #{MapSet.size(recent_message_ids)} RECENT")

      Helpers.send_response(
        state.socket,
        "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $Forwarded $MDNSent Junk NonJunk)"
      )

      Helpers.send_response(
        state.socket,
        "* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $Forwarded $MDNSent \\*)] Permanent flags"
      )

      Helpers.send_response(state.socket, "* OK [UIDVALIDITY #{state.uid_validity}] UIDs valid")

      Helpers.send_response(
        state.socket,
        "* OK [UIDNEXT #{Helpers.get_next_uid(messages)}] Predicted next UID"
      )

      if first_unseen > 0 do
        Helpers.send_response(state.socket, "* OK [UNSEEN #{first_unseen}] First unseen message")
      end

      Helpers.send_response(state.socket, "* OK [HIGHESTMODSEQ 1] Highest modseq")
      Helpers.send_response(state.socket, "#{tag} OK [READ-WRITE] SELECT completed")

      {:continue,
       Map.merge(state, %{
         selected_folder: canonical_folder,
         messages: messages,
         recent_message_ids: recent_message_ids,
         folder_key: folder_key,
         state: :selected
       })}
    else
      {:error, :missing_mailbox_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing mailbox name")
        {:continue, state}
    end
  end

  def handle_examine(tag, args, state) do
    with {:ok, folder} <- Helpers.parse_mailbox_arg(args),
         {:ok, messages} <- Shared.load_folder_messages(state.mailbox, folder) do
      canonical_folder = Helpers.canonical_system_folder_name(folder)
      folder_key = RecentState.folder_key_for_mailbox(state.mailbox, canonical_folder)

      recent_message_ids =
        RecentState.claim_recent_message_ids(state.mailbox, folder_key, messages)

      _unseen_count = Helpers.count_unseen(messages)
      first_unseen = find_first_unseen(messages)
      Helpers.send_response(state.socket, "* #{length(messages)} EXISTS")
      Helpers.send_response(state.socket, "* #{MapSet.size(recent_message_ids)} RECENT")

      Helpers.send_response(
        state.socket,
        "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $Forwarded $MDNSent Junk NonJunk)"
      )

      Helpers.send_response(
        state.socket,
        "* OK [PERMANENTFLAGS ()] No permanent flags in read-only mode"
      )

      Helpers.send_response(state.socket, "* OK [UIDVALIDITY #{state.uid_validity}] UIDs valid")

      Helpers.send_response(
        state.socket,
        "* OK [UIDNEXT #{Helpers.get_next_uid(messages)}] Predicted next UID"
      )

      if first_unseen > 0 do
        Helpers.send_response(state.socket, "* OK [UNSEEN #{first_unseen}] First unseen message")
      end

      Helpers.send_response(state.socket, "* OK [HIGHESTMODSEQ 1] Highest modseq")
      Helpers.send_response(state.socket, "#{tag} OK [READ-ONLY] EXAMINE completed")

      {:continue,
       Map.merge(state, %{
         selected_folder: canonical_folder,
         messages: messages,
         recent_message_ids: recent_message_ids,
         folder_key: folder_key,
         state: :selected
       })}
    else
      {:error, :missing_mailbox_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing mailbox name")
        {:continue, state}
    end
  end

  defp find_first_unseen(messages) do
    case Enum.find_index(messages, fn msg -> !msg.read end) do
      nil -> 0
      idx -> idx + 1
    end
  end

  def handle_list(tag, args, state) do
    %{
      pattern: pattern,
      return_status_items: return_status_items,
      select_subscribed: select_subscribed
    } = Folders.parse_list_command_args(args)

    all_folders = Folders.all_for_user(state.user.id)

    candidate_folders =
      if select_subscribed do
        subscribed = Folders.subscribed_folder_set(state.user.id, all_folders)

        Enum.filter(all_folders, fn {folder, _attrs} ->
          MapSet.member?(subscribed, folder)
        end)
      else
        all_folders
      end

    folders = Folders.filter_by_pattern(candidate_folders, pattern)

    Enum.each(folders, fn {folder, attrs} ->
      escaped = Helpers.escape_imap_string(folder)
      Helpers.send_response(state.socket, "* LIST (#{attrs}) \"/\" \"#{escaped}\"")
      maybe_send_list_status(folder, return_status_items, state)
    end)

    Helpers.send_response(state.socket, "#{tag} OK LIST completed")
    {:continue, state}
  end

  def handle_lsub(tag, args, state) do
    {_reference, pattern} = Helpers.parse_list_args(args)
    all_folders = Folders.all_for_user(state.user.id)
    subscribed = Folders.subscribed_folder_set(state.user.id, all_folders)

    folders =
      all_folders
      |> Enum.filter(fn {folder, _attrs} -> MapSet.member?(subscribed, folder) end)
      |> Folders.filter_by_pattern(pattern)

    Enum.each(folders, fn {folder, attrs} ->
      escaped = Helpers.escape_imap_string(folder)
      Helpers.send_response(state.socket, "* LSUB (#{attrs}) \"/\" \"#{escaped}\"")
    end)

    Helpers.send_response(state.socket, "#{tag} OK LSUB completed")
    {:continue, state}
  end

  def handle_xlist(tag, args, state) do
    handle_list(tag, args, state)
  end

  def handle_subscribe(tag, args, state) do
    all_folders = Folders.all_for_user(state.user.id)
    folder_names = Enum.map(all_folders, fn {folder, _attrs} -> folder end)

    with {:ok, folder_name} <- Folders.parse_folder_name_argument(args),
         true <- Folders.destination_folder_exists?(folder_name, state.user.id),
         :ok <- Folders.seed_subscriptions_if_needed(state.user.id, folder_names),
         {:ok, _subscription} <-
           Elektrine.Email.ImapSubscriptions.subscribe_folder(
             state.user.id,
             Folders.canonical_folder_name(folder_name, all_folders)
           ) do
      Helpers.send_response(state.socket, "#{tag} OK SUBSCRIBE completed")
    else
      {:error, :missing_folder_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing folder name")

      false ->
        Helpers.send_response(state.socket, "#{tag} NO [NONEXISTENT] Folder does not exist")

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to subscribe folder")
    end

    {:continue, state}
  end

  def handle_unsubscribe(tag, args, state) do
    all_folders = Folders.all_for_user(state.user.id)
    folder_names = Enum.map(all_folders, fn {folder, _attrs} -> folder end)

    with {:ok, folder_name} <- Folders.parse_folder_name_argument(args),
         true <- Folders.destination_folder_exists?(folder_name, state.user.id),
         :ok <- Folders.seed_subscriptions_if_needed(state.user.id, folder_names),
         :ok <-
           Elektrine.Email.ImapSubscriptions.unsubscribe_folder(
             state.user.id,
             Folders.canonical_folder_name(folder_name, all_folders)
           ) do
      Helpers.send_response(state.socket, "#{tag} OK UNSUBSCRIBE completed")
    else
      {:error, :missing_folder_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing folder name")

      false ->
        Helpers.send_response(state.socket, "#{tag} NO [NONEXISTENT] Folder does not exist")

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to unsubscribe folder")
    end

    {:continue, state}
  end

  def handle_getquotaroot(tag, args, state) do
    folder = String.trim(args || "INBOX", "\"")
    {used_kib, limit_kib} = user_quota_storage(state)
    Helpers.send_response(state.socket, "* QUOTAROOT \"#{folder}\" \"\"")
    Helpers.send_response(state.socket, "* QUOTA \"\" (STORAGE #{used_kib} #{limit_kib})")
    Helpers.send_response(state.socket, "#{tag} OK GETQUOTAROOT completed")
    {:continue, state}
  end

  def handle_getquota(tag, _args, state) do
    {used_kib, limit_kib} = user_quota_storage(state)
    Helpers.send_response(state.socket, "* QUOTA \"\" (STORAGE #{used_kib} #{limit_kib})")
    Helpers.send_response(state.socket, "#{tag} OK GETQUOTA completed")
    {:continue, state}
  end

  defp user_quota_storage(state) do
    user_id =
      case Map.get(state, :user) do
        %{id: id} when is_integer(id) -> id
        _ -> nil
      end

    user =
      if is_integer(user_id) do
        Elektrine.Repo.get(Elektrine.Accounts.User, user_id)
      end

    used_bytes =
      case user do
        %{storage_used_bytes: used_bytes} when is_integer(used_bytes) and used_bytes >= 0 ->
          used_bytes

        _ ->
          0
      end

    limit_bytes =
      case user do
        %{storage_limit_bytes: limit_bytes} when is_integer(limit_bytes) and limit_bytes >= 0 ->
          limit_bytes

        _ ->
          @default_storage_limit_bytes
      end

    {bytes_to_imap_quota_units(used_bytes), bytes_to_imap_quota_units(limit_bytes)}
  end

  # RFC 2087 `STORAGE` values are in units of 1024 octets.
  defp bytes_to_imap_quota_units(bytes) when is_integer(bytes) and bytes >= 0 do
    div(bytes + 1023, 1024)
  end

  defp bytes_to_imap_quota_units(_), do: 0

  def handle_create(tag, args, state) do
    with {:ok, folder_name} <- Folders.parse_folder_name_argument(args),
         false <- Folders.system_folder_name?(folder_name),
         {:ok, _folder} <-
           Elektrine.Email.create_custom_folder(%{
             name: folder_name,
             user_id: state.user.id,
             color: "#3b82f6",
             icon: "folder"
           }),
         :ok <- Folders.maybe_subscribe_new_folder(state.user.id, folder_name) do
      Helpers.send_response(state.socket, "#{tag} OK CREATE completed")
    else
      {:error, :missing_folder_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing folder name")

      true ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Cannot create system folders")

      {:error, :limit_reached} ->
        Helpers.send_response(state.socket, "#{tag} NO [LIMIT] Folder limit reached")

      {:error, %Ecto.Changeset{} = changeset} ->
        if Folders.duplicate_folder_name_error?(changeset) do
          Helpers.send_response(state.socket, "#{tag} NO [ALREADYEXISTS] Folder already exists")
        else
          Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Invalid folder name")
        end

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to create folder")
    end

    {:continue, state}
  end

  def handle_delete(tag, args, state) do
    with {:ok, folder_name} <- Folders.parse_folder_name_argument(args),
         false <- Folders.system_folder_name?(folder_name),
         folder when not is_nil(folder) <-
           Folders.find_custom_folder_by_name(state.user.id, folder_name),
         {:ok, _deleted_folder} <- Elektrine.Email.delete_custom_folder(folder),
         :ok <-
           Elektrine.Email.ImapSubscriptions.remove_folder_subscription(
             state.user.id,
             folder.name
           ) do
      Helpers.send_response(state.socket, "#{tag} OK DELETE completed")
    else
      {:error, :missing_folder_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing folder name")

      true ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Cannot delete system folders")

      nil ->
        Helpers.send_response(state.socket, "#{tag} NO [NONEXISTENT] Folder does not exist")

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to delete folder")
    end

    {:continue, state}
  end

  def handle_rename(tag, args, state) do
    with {:ok, old_name, new_name} <- Folders.parse_rename_arguments(args),
         false <- Folders.system_folder_name?(old_name),
         false <- Folders.system_folder_name?(new_name),
         folder when not is_nil(folder) <-
           Folders.find_custom_folder_by_name(state.user.id, old_name),
         {:ok, _updated_folder} <- Elektrine.Email.update_custom_folder(folder, %{name: new_name}),
         :ok <-
           Elektrine.Email.ImapSubscriptions.rename_folder_subscription(
             state.user.id,
             folder.name,
             new_name
           ) do
      Helpers.send_response(state.socket, "#{tag} OK RENAME completed")
    else
      {:error, :invalid_rename_args} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid RENAME arguments")

      true ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Cannot rename system folders")

      nil ->
        Helpers.send_response(state.socket, "#{tag} NO [NONEXISTENT] Folder does not exist")

      {:error, %Ecto.Changeset{} = changeset} ->
        if Folders.duplicate_folder_name_error?(changeset) do
          Helpers.send_response(state.socket, "#{tag} NO [ALREADYEXISTS] Folder already exists")
        else
          Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Invalid destination folder")
        end

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to rename folder")
    end

    {:continue, state}
  end

  defp maybe_send_list_status(_folder, [], _state), do: :ok

  defp maybe_send_list_status(folder, status_items, state) do
    if state.mailbox do
      {:ok, messages} = Shared.load_folder_messages(state.mailbox, folder)
      items = build_status_items(messages, status_items, state, folder)
      escaped_folder = Helpers.escape_imap_string(folder)
      Helpers.send_response(state.socket, "* STATUS \"#{escaped_folder}\" (#{items})")
    end
  end

  def handle_status(tag, args, state) do
    case Helpers.parse_status_args(args) do
      {:ok, folder, items} ->
        {:ok, messages} = Shared.load_folder_messages(state.mailbox, folder)
        status_items = build_status_items(messages, items, state, folder)

        escaped_folder = Helpers.escape_imap_string(folder)
        Helpers.send_response(state.socket, "* STATUS \"#{escaped_folder}\" (#{status_items})")
        Helpers.send_response(state.socket, "#{tag} OK STATUS completed")

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid STATUS arguments")
    end

    {:continue, state}
  end

  defp build_status_items(messages, items, state, folder) do
    items
    |> Enum.map(fn item ->
      case String.upcase(item) do
        "MESSAGES" -> "MESSAGES #{length(messages)}"
        "RECENT" -> "RECENT #{RecentState.status_recent_count(messages, state, folder)}"
        "UNSEEN" -> "UNSEEN #{Helpers.count_unseen(messages)}"
        "UIDNEXT" -> "UIDNEXT #{Helpers.get_next_uid(messages)}"
        "UIDVALIDITY" -> "UIDVALIDITY #{state.uid_validity}"
        "SIZE" -> "SIZE #{calculate_folder_size(messages, state.user.id)}"
        "HIGHESTMODSEQ" -> "HIGHESTMODSEQ 1"
        "DELETED" -> "DELETED 0"
        "DELETEDSTORAGE" -> "DELETEDSTORAGE 0"
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp calculate_folder_size(messages, user_id) do
    Enum.reduce(messages, 0, fn msg, acc ->
      full_msg =
        if Map.has_key?(msg, :text_body) and msg.text_body != nil do
          msg
        else
          import Ecto.Query

          query =
            from(m in Elektrine.Email.Message,
              where: m.id == ^msg.id,
              select: %{
                id: m.id,
                encrypted_text_body: m.encrypted_text_body,
                encrypted_html_body: m.encrypted_html_body
              }
            )

          case Elektrine.Repo.one(query) do
            nil -> %{text_body: "", html_body: ""}
            partial_msg -> Elektrine.Email.Message.decrypt_content(partial_msg, user_id)
          end
        end

      acc + byte_size(full_msg.text_body || "") + byte_size(full_msg.html_body || "")
    end)
  end
end
