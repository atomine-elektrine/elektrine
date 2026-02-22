defmodule Elektrine.IMAP.Commands do
  @moduledoc "IMAP command processing and handling.\nImplements all IMAP4rev1 commands and extensions (IDLE, UIDPLUS, etc).\n"
  require Logger
  alias Elektrine.Constants
  alias Elektrine.Email.AttachmentStorage
  alias Elektrine.IMAP.{Helpers, Response}
  alias Elektrine.Mail.Telemetry, as: MailTelemetry
  alias Elektrine.MailAuth.RateLimiter, as: MailAuthRateLimiter
  @max_message_size Constants.imap_max_message_size()
  @max_idle_per_ip Constants.imap_max_idle_per_ip()
  @idle_timeout_ms Constants.imap_idle_timeout_ms()
  @idle_stale_grace_ms 60_000
  @authenticated_capabilities [
    "IMAP4rev1",
    "UIDPLUS",
    "IDLE",
    "UNSELECT",
    "NAMESPACE",
    "ID",
    "ENABLE",
    "MOVE",
    "SPECIAL-USE",
    "LITERAL+",
    "CHILDREN",
    "SORT",
    "XLIST",
    "STATUS=SIZE"
  ]
  @unauthenticated_capabilities ["AUTH=PLAIN", "AUTH=LOGIN" | @authenticated_capabilities]
  @system_folders [
    {"INBOX", "\\HasNoChildren"},
    {"Sent", "\\HasNoChildren \\Sent"},
    {"Drafts", "\\HasNoChildren \\Drafts"},
    {"Trash", "\\HasNoChildren \\Trash"},
    {"Spam", "\\HasNoChildren \\Junk"}
  ]
  @doc false
  def capability_string(state \\ :not_authenticated)

  def capability_string(:not_authenticated) do
    Enum.join(@unauthenticated_capabilities, " ")
  end

  def capability_string(_state) do
    Enum.join(@authenticated_capabilities, " ")
  end

  @doc "Process IMAP command"
  def process_command(tag, cmd, args, state) do
    case String.upcase(cmd) do
      "CAPABILITY" ->
        handle_capability(tag, state)

      "NOOP" ->
        handle_noop_any_state(tag, state)

      "LOGOUT" ->
        handle_logout(tag, state)

      "ID" ->
        handle_id(tag, args, state)

      "STARTTLS" when state.state == :not_authenticated ->
        handle_starttls(tag, state)

      "AUTHENTICATE" when state.state == :not_authenticated ->
        handle_authenticate(tag, args, state)

      "LOGIN" when state.state == :not_authenticated ->
        handle_login(tag, args, state)

      "SELECT" when state.state in [:authenticated, :selected] ->
        handle_select(tag, args, state)

      "EXAMINE" when state.state in [:authenticated, :selected] ->
        handle_examine(tag, args, state)

      "LIST" when state.state in [:authenticated, :selected] ->
        handle_list(tag, args, state)

      "LSUB" when state.state in [:authenticated, :selected] ->
        handle_lsub(tag, args, state)

      "XLIST" when state.state in [:authenticated, :selected] ->
        handle_xlist(tag, args, state)

      "SUBSCRIBE" when state.state in [:authenticated, :selected] ->
        handle_subscribe(tag, args, state)

      "UNSUBSCRIBE" when state.state in [:authenticated, :selected] ->
        handle_unsubscribe(tag, args, state)

      "NAMESPACE" when state.state in [:authenticated, :selected] ->
        handle_namespace(tag, state)

      "ENABLE" when state.state in [:authenticated, :selected] ->
        handle_enable(tag, args, state)

      "CREATE" when state.state in [:authenticated, :selected] ->
        handle_create(tag, args, state)

      "DELETE" when state.state in [:authenticated, :selected] ->
        handle_delete(tag, args, state)

      "RENAME" when state.state in [:authenticated, :selected] ->
        handle_rename(tag, args, state)

      "STATUS" when state.state in [:authenticated, :selected] ->
        handle_status(tag, args, state)

      "APPEND" when state.state in [:authenticated, :selected] ->
        handle_append(tag, args, state)

      "GETQUOTAROOT" when state.state in [:authenticated, :selected] ->
        handle_getquotaroot(tag, args, state)

      "GETQUOTA" when state.state in [:authenticated, :selected] ->
        handle_getquota(tag, args, state)

      "UID" when state.state == :selected ->
        handle_uid(tag, args, state)

      "SEARCH" when state.state == :selected ->
        handle_search(tag, args, state)

      "SORT" when state.state == :selected ->
        handle_sort(tag, args, state)

      "FETCH" when state.state == :selected ->
        handle_fetch(tag, args, state)

      "COPY" when state.state == :selected ->
        handle_copy(tag, args, state)

      "MOVE" when state.state == :selected ->
        handle_move(tag, args, state)

      "STORE" when state.state == :selected ->
        handle_store(tag, args, state)

      "EXPUNGE" when state.state == :selected ->
        handle_expunge(tag, state)

      "CHECK" when state.state == :selected ->
        handle_check(tag, state)

      "CLOSE" when state.state == :selected ->
        handle_close(tag, state)

      "UNSELECT" when state.state == :selected ->
        handle_unselect(tag, state)

      "IDLE" when state.state == :selected ->
        handle_idle(tag, state)

      _ ->
        handle_unrecognized(tag, cmd, state)
    end
  end

  defp handle_capability(tag, state) do
    Helpers.send_response(state.socket, "* CAPABILITY #{capability_string(state.state)}")
    Helpers.send_response(state.socket, "#{tag} OK CAPABILITY completed")
    {:continue, state}
  end

  defp handle_starttls(tag, state) do
    Helpers.send_response(state.socket, "#{tag} NO STARTTLS not available (use port 993 for TLS)")
    {:continue, state}
  end

  defp handle_noop_any_state(tag, state) do
    if state.state == :selected && state.mailbox && state.selected_folder do
      {:ok, fresh_messages} = load_folder_messages(state.mailbox, state.selected_folder)

      if length(fresh_messages) != length(state.messages) do
        Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")
        Helpers.send_response(state.socket, "* #{length(fresh_messages)} RECENT")
      end

      Helpers.send_response(state.socket, "#{tag} OK NOOP completed")
      {:continue, %{state | messages: fresh_messages}}
    else
      Helpers.send_response(state.socket, "#{tag} OK NOOP completed")
      {:continue, state}
    end
  end

  defp handle_authenticate(tag, args, state) do
    case String.upcase(args || "") do
      "PLAIN" ->
        Helpers.send_response(state.socket, "+")

        case :gen_tcp.recv(state.socket, 0, 60_000) do
          {:ok, data} ->
            credentials = data |> to_string() |> String.trim()

            case Helpers.decode_auth_plain(credentials) do
              {:ok, username, password} ->
                do_authenticate(tag, username, password, state)

              {:error, _} ->
                Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
                {:continue, state}
            end

          {:error, _} ->
            Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
            {:continue, state}
        end

      "LOGIN" ->
        Helpers.send_response(state.socket, "+ VXNlcm5hbWU6")

        case :gen_tcp.recv(state.socket, 0, 60_000) do
          {:ok, username_data} ->
            username =
              username_data |> to_string() |> String.trim() |> Base.decode64!() |> String.trim()

            Helpers.send_response(state.socket, "+ UGFzc3dvcmQ6")

            case :gen_tcp.recv(state.socket, 0, 60_000) do
              {:ok, password_data} ->
                password =
                  password_data
                  |> to_string()
                  |> String.trim()
                  |> Base.decode64!()
                  |> String.trim()

                do_authenticate(tag, username, password, state)

              {:error, _} ->
                Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
                {:continue, state}
            end

          {:error, _} ->
            Helpers.send_response(state.socket, "#{tag} NO AUTHENTICATE failed")
            {:continue, state}
        end

      _ ->
        Helpers.send_response(state.socket, "#{tag} NO Unsupported authentication mechanism")
        {:continue, state}
    end
  end

  defp handle_login(tag, args, state) do
    case Helpers.parse_login_args(args) do
      {:ok, username, password} ->
        do_authenticate(tag, username, password, state)

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid LOGIN arguments")
        {:continue, state}
    end
  end

  defp handle_logout(tag, state) do
    Helpers.send_response(state.socket, "* BYE Logging out")
    Helpers.send_response(state.socket, "#{tag} OK LOGOUT completed")
    {:logout, state}
  end

  defp handle_select(tag, args, state) do
    folder = String.trim(args || "", "\"")
    {:ok, messages} = load_folder_messages(state.mailbox, folder)
    unseen_count = Helpers.count_unseen(messages)
    first_unseen = find_first_unseen(messages)
    Helpers.send_response(state.socket, "* #{length(messages)} EXISTS")
    Helpers.send_response(state.socket, "* #{unseen_count} RECENT")

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
    {:continue, %{state | selected_folder: folder, messages: messages, state: :selected}}
  end

  defp handle_examine(tag, args, state) do
    folder = String.trim(args || "", "\"")
    {:ok, messages} = load_folder_messages(state.mailbox, folder)
    _unseen_count = Helpers.count_unseen(messages)
    first_unseen = find_first_unseen(messages)
    Helpers.send_response(state.socket, "* #{length(messages)} EXISTS")
    Helpers.send_response(state.socket, "* 0 RECENT")

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
    {:continue, %{state | selected_folder: folder, messages: messages, state: :selected}}
  end

  defp find_first_unseen(messages) do
    case Enum.find_index(messages, fn msg -> !msg.read end) do
      nil -> 0
      idx -> idx + 1
    end
  end

  defp handle_list(tag, args, state) do
    {_reference, pattern} = Helpers.parse_list_args(args)
    all_folders = all_folders_for_user(state.user.id)

    folders =
      case pattern do
        "*" ->
          all_folders

        "%" ->
          all_folders

        pattern_str ->
          Enum.filter(all_folders, fn {name, _} ->
            Helpers.matches_pattern?(String.downcase(name), String.downcase(pattern_str))
          end)
      end

    Enum.each(folders, fn {folder, attrs} ->
      escaped = Helpers.escape_imap_string(folder)
      Helpers.send_response(state.socket, "* LIST (#{attrs}) \"/\" \"#{escaped}\"")
    end)

    Helpers.send_response(state.socket, "#{tag} OK LIST completed")
    {:continue, state}
  end

  defp handle_lsub(tag, args, state) do
    {_reference, pattern} = Helpers.parse_list_args(args)
    all_folders = all_folders_for_user(state.user.id)

    folders =
      case pattern do
        "*" ->
          all_folders

        "%" ->
          all_folders

        pattern_str ->
          Enum.filter(all_folders, fn {name, _} ->
            Helpers.matches_pattern?(String.downcase(name), String.downcase(pattern_str))
          end)
      end

    Enum.each(folders, fn {folder, attrs} ->
      escaped = Helpers.escape_imap_string(folder)
      Helpers.send_response(state.socket, "* LSUB (#{attrs}) \"/\" \"#{escaped}\"")
    end)

    Helpers.send_response(state.socket, "#{tag} OK LSUB completed")
    {:continue, state}
  end

  defp handle_subscribe(tag, _args, state) do
    Helpers.send_response(state.socket, "#{tag} OK SUBSCRIBE completed")
    {:continue, state}
  end

  defp handle_unsubscribe(tag, _args, state) do
    Helpers.send_response(state.socket, "#{tag} OK UNSUBSCRIBE completed")
    {:continue, state}
  end

  defp handle_namespace(tag, state) do
    Helpers.send_response(state.socket, "* NAMESPACE ((\"\" \"/\")) NIL NIL")
    Helpers.send_response(state.socket, "#{tag} OK NAMESPACE completed")
    {:continue, state}
  end

  defp handle_id(tag, _args, state) do
    Helpers.send_response(
      state.socket,
      "* ID (\"name\" \"Elektrine\" \"version\" \"1.0\" \"vendor\" \"Elektrine\" \"support-url\" \"https://elektrine.com\")"
    )

    Helpers.send_response(state.socket, "#{tag} OK ID completed")
    {:continue, state}
  end

  defp handle_xlist(tag, args, state) do
    handle_list(tag, args, state)
  end

  defp handle_getquotaroot(tag, args, state) do
    folder = String.trim(args || "INBOX", "\"")
    Helpers.send_response(state.socket, "* QUOTAROOT \"#{folder}\" \"\"")
    Helpers.send_response(state.socket, "* QUOTA \"\" (STORAGE 0 1048576)")
    Helpers.send_response(state.socket, "#{tag} OK GETQUOTAROOT completed")
    {:continue, state}
  end

  defp handle_getquota(tag, _args, state) do
    Helpers.send_response(state.socket, "* QUOTA \"\" (STORAGE 0 1048576)")
    Helpers.send_response(state.socket, "#{tag} OK GETQUOTA completed")
    {:continue, state}
  end

  defp handle_sort(tag, args, state) do
    case parse_sort_args(args) do
      {:ok, sort_criteria, _charset, search_criteria} ->
        max_sequence = length(state.messages)

        matching =
          state.messages
          |> Enum.with_index(1)
          |> Enum.filter(fn {msg, sequence_number} ->
            Helpers.matches_search_criteria?(msg, search_criteria, sequence_number, max_sequence)
          end)

        sorted = sort_messages(matching, sort_criteria)
        uids = Enum.map_join(sorted, " ", fn {msg, _idx} -> msg.id end)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK SORT completed")

      {:error, _} ->
        uids = Enum.map_join(state.messages, " ", & &1.id)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK SORT completed")
    end

    {:continue, state}
  end

  defp parse_sort_args(nil) do
    {:error, :missing_args}
  end

  defp parse_sort_args(args) do
    case Regex.run(~r/\(([^)]+)\)\s+(\S+)\s*(.*)/i, args) do
      [_, criteria, charset, search] ->
        {:ok, String.split(criteria), charset, String.upcase(search || "ALL")}

      _ ->
        {:error, :invalid_format}
    end
  end

  defp sort_messages(messages, criteria) do
    Enum.sort_by(messages, fn {msg, _idx} ->
      Enum.map(criteria, fn crit ->
        case String.upcase(crit) do
          "DATE" -> msg.inserted_at
          "REVERSE" -> nil
          "FROM" -> msg.from || ""
          "TO" -> msg.to || ""
          "SUBJECT" -> msg.subject || ""
          "SIZE" -> byte_size(Map.get(msg, :text_body) || "")
          "ARRIVAL" -> msg.inserted_at
          _ -> nil
        end
      end)
    end)
  end

  defp handle_enable(tag, args, state) do
    extensions = String.split(args || "", " ") |> Enum.reject(&(&1 == ""))

    enabled =
      Enum.filter(extensions, fn ext -> String.upcase(ext) in ["UIDPLUS", "IDLE", "UNSELECT"] end)

    if enabled != [] do
      Helpers.send_response(state.socket, "* ENABLED #{Enum.join(enabled, " ")}")
    end

    Helpers.send_response(state.socket, "#{tag} OK ENABLE completed")
    {:continue, state}
  end

  defp handle_create(tag, args, state) do
    with {:ok, folder_name} <- parse_folder_name_argument(args),
         false <- system_folder_name?(folder_name),
         {:ok, _folder} <-
           Elektrine.Email.create_custom_folder(%{
             name: folder_name,
             user_id: state.user.id,
             color: "#3b82f6",
             icon: "folder"
           }) do
      Helpers.send_response(state.socket, "#{tag} OK CREATE completed")
    else
      {:error, :missing_folder_name} ->
        Helpers.send_response(state.socket, "#{tag} BAD Missing folder name")

      true ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Cannot create system folders")

      {:error, :limit_reached} ->
        Helpers.send_response(state.socket, "#{tag} NO [LIMIT] Folder limit reached")

      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_folder_name_error?(changeset) do
          Helpers.send_response(state.socket, "#{tag} NO [ALREADYEXISTS] Folder already exists")
        else
          Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Invalid folder name")
        end

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to create folder")
    end

    {:continue, state}
  end

  defp handle_delete(tag, args, state) do
    with {:ok, folder_name} <- parse_folder_name_argument(args),
         false <- system_folder_name?(folder_name),
         folder when not is_nil(folder) <- find_custom_folder_by_name(state.user.id, folder_name),
         {:ok, _deleted_folder} <- Elektrine.Email.delete_custom_folder(folder) do
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

  defp handle_rename(tag, args, state) do
    with {:ok, old_name, new_name} <- parse_rename_arguments(args),
         false <- system_folder_name?(old_name),
         false <- system_folder_name?(new_name),
         folder when not is_nil(folder) <- find_custom_folder_by_name(state.user.id, old_name),
         {:ok, _updated_folder} <- Elektrine.Email.update_custom_folder(folder, %{name: new_name}) do
      Helpers.send_response(state.socket, "#{tag} OK RENAME completed")
    else
      {:error, :invalid_rename_args} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid RENAME arguments")

      true ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Cannot rename system folders")

      nil ->
        Helpers.send_response(state.socket, "#{tag} NO [NONEXISTENT] Folder does not exist")

      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_folder_name_error?(changeset) do
          Helpers.send_response(state.socket, "#{tag} NO [ALREADYEXISTS] Folder already exists")
        else
          Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Invalid destination folder")
        end

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} NO [CANNOT] Failed to rename folder")
    end

    {:continue, state}
  end

  defp all_folders_for_user(user_id) do
    custom_folders = Elektrine.Email.list_custom_folders(user_id)

    custom_folder_rows =
      Enum.map(custom_folders, fn folder ->
        has_children = Enum.any?(custom_folders, &(&1.parent_id == folder.id))

        attrs =
          if has_children do
            "\\HasChildren"
          else
            "\\HasNoChildren"
          end

        {folder.name, attrs}
      end)

    @system_folders ++ custom_folder_rows
  end

  defp system_folder_name?(folder_name) when is_binary(folder_name) do
    normalized = String.upcase(String.trim(folder_name))
    Enum.any?(@system_folders, fn {name, _attrs} -> String.upcase(name) == normalized end)
  end

  defp parse_folder_name_argument(args) do
    case String.trim(args || "") do
      "" ->
        {:error, :missing_folder_name}

      trimmed ->
        case Regex.run(~r/"([^"]+)"/, trimmed) do
          [_, folder_name] -> {:ok, String.trim(folder_name)}
          _ -> {:ok, trimmed |> String.trim("\"") |> String.trim()}
        end
    end
  end

  defp parse_rename_arguments(args) do
    trimmed = String.trim(args || "")

    case Regex.run(~r/"([^"]+)"\s+"([^"]+)"/, trimmed) do
      [_, old_name, new_name] ->
        {:ok, String.trim(old_name), String.trim(new_name)}

      _ ->
        case String.split(trimmed, ~r/\s+/, parts: 2) do
          [old_name, new_name] -> {:ok, String.trim(old_name, "\""), String.trim(new_name, "\"")}
          _ -> {:error, :invalid_rename_args}
        end
    end
  end

  defp duplicate_folder_name_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_message, metadata}} -> metadata[:constraint] == :unique
      _ -> false
    end)
  end

  defp find_custom_folder_by_name(user_id, folder_name)
       when is_integer(user_id) and is_binary(folder_name) do
    target_name = String.downcase(String.trim(folder_name))

    user_id
    |> Elektrine.Email.list_custom_folders()
    |> Enum.find(fn folder -> String.downcase(folder.name) == target_name end)
  end

  defp destination_folder_exists?(folder_name, user_id) when is_binary(folder_name) do
    system_folder_name?(folder_name) or
      (is_integer(user_id) and not is_nil(find_custom_folder_by_name(user_id, folder_name)))
  end

  defp handle_status(tag, args, state) do
    case Helpers.parse_status_args(args) do
      {:ok, folder, items} ->
        {:ok, messages} = load_folder_messages(state.mailbox, folder)

        status_items =
          Enum.map(items, fn item ->
            case String.upcase(item) do
              "MESSAGES" -> "MESSAGES #{length(messages)}"
              "RECENT" -> "RECENT #{Helpers.count_unseen(messages)}"
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

        escaped_folder = Helpers.escape_imap_string(folder)
        Helpers.send_response(state.socket, "* STATUS \"#{escaped_folder}\" (#{status_items})")
        Helpers.send_response(state.socket, "#{tag} OK STATUS completed")

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid STATUS arguments")
    end

    {:continue, state}
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

  defp handle_append(tag, args, state) do
    case Helpers.parse_append_args(args) do
      {:ok, folder, _flags, size, is_literal_plus} ->
        unless is_literal_plus do
          Helpers.send_response(state.socket, "+ Ready for literal data")
        end

        case receive_literal_data(state.socket, size) do
          {:ok, data} ->
            store_result =
              try do
                :timer.tc(fn -> store_append_message(state.mailbox, folder, data) end)
              rescue
                e ->
                  Logger.error("IMAP APPEND: Exception during store: #{inspect(e)}")
                  {{0, {:error, :store_exception}}}
              end

            case store_result do
              {_time_us, {:ok, message}} ->
                if message.has_attachments && message.attachments &&
                     map_size(message.attachments) > 0 do
                  Task.start(fn ->
                    Elektrine.Jobs.AttachmentUploader.upload_message_attachments(message.id)
                  end)
                end

                if String.upcase(folder) == String.upcase(state.selected_folder || "") do
                  {:ok, fresh_messages} =
                    load_folder_messages(state.mailbox, state.selected_folder)

                  Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")
                end

                Helpers.send_response(
                  state.socket,
                  "#{tag} OK [APPENDUID #{state.uid_validity} #{message.id}] APPEND completed"
                )

              {_time_us, {:error, reason}} ->
                Logger.error("IMAP APPEND: Store failed: #{inspect(reason)}")

                if reason == :unknown_folder do
                  Helpers.send_response(
                    state.socket,
                    "#{tag} NO [TRYCREATE] Destination folder does not exist"
                  )
                else
                  Helpers.send_response(state.socket, "#{tag} NO APPEND failed")
                end
            end

          {:error, :message_too_large} ->
            Helpers.send_response(state.socket, "#{tag} NO [TOOBIG] Message exceeds size limit")

          {:error, reason} ->
            Logger.error("APPEND receive data failed: #{inspect(reason)}")
            Helpers.send_response(state.socket, "#{tag} NO APPEND failed")
        end

      {:error, reason} ->
        Logger.error("APPEND parse failed: #{inspect(reason)}")
        Helpers.send_response(state.socket, "#{tag} BAD Invalid APPEND arguments")
    end

    {:continue, state}
  end

  defp handle_uid(tag, args, state) do
    case String.split(args || "", " ", parts: 2) do
      [subcommand, subargs] ->
        case String.upcase(subcommand) do
          "FETCH" ->
            handle_uid_fetch(tag, subargs, state)

          "STORE" ->
            handle_uid_store(tag, subargs, state)

          "SEARCH" ->
            handle_uid_search(tag, subargs, state)

          "COPY" ->
            handle_uid_copy(tag, subargs, state)

          "MOVE" ->
            handle_uid_move(tag, subargs, state)

          "EXPUNGE" ->
            handle_uid_expunge(tag, subargs, state)

          "SORT" ->
            handle_uid_sort(tag, subargs, state)

          "THREAD" ->
            handle_uid_thread(tag, subargs, state)

          _other ->
            Helpers.send_response(state.socket, "#{tag} BAD UID command not implemented")
            {:continue, state}
        end

      [subcommand] ->
        case String.upcase(subcommand) do
          "EXPUNGE" ->
            handle_uid_expunge(tag, nil, state)

          _ ->
            Helpers.send_response(state.socket, "#{tag} BAD UID command requires arguments")
            {:continue, state}
        end

      _other ->
        Helpers.send_response(state.socket, "#{tag} BAD UID command format invalid")
        {:continue, state}
    end
  end

  defp handle_uid_sort(tag, args, state) do
    case parse_sort_args(args) do
      {:ok, sort_criteria, _charset, search_criteria} ->
        max_sequence = length(state.messages)

        matching =
          state.messages
          |> Enum.with_index(1)
          |> Enum.filter(fn {msg, sequence_number} ->
            Helpers.matches_search_criteria?(msg, search_criteria, sequence_number, max_sequence)
          end)

        sorted = sort_messages(matching, sort_criteria)
        uids = Enum.map_join(sorted, " ", fn {msg, _idx} -> msg.id end)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK UID SORT completed")

      {:error, _} ->
        uids = Enum.map_join(state.messages, " ", & &1.id)
        Helpers.send_response(state.socket, "* SORT #{uids}")
        Helpers.send_response(state.socket, "#{tag} OK UID SORT completed")
    end

    {:continue, state}
  end

  defp handle_uid_thread(tag, _args, state) do
    threads = state.messages |> Enum.map_join("", fn msg -> "(#{msg.id})" end)
    Helpers.send_response(state.socket, "* THREAD #{threads}")
    Helpers.send_response(state.socket, "#{tag} OK UID THREAD completed")
    {:continue, state}
  end

  defp handle_search(tag, args, state) do
    criteria = String.upcase(args || "ALL")
    max_sequence = length(state.messages)

    matching_sequence_numbers =
      state.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {msg, sequence_number} ->
        Helpers.matches_search_criteria?(msg, criteria, sequence_number, max_sequence)
      end)
      |> Enum.map(fn {_msg, seq_num} -> seq_num end)

    seq_list = Enum.join(matching_sequence_numbers, " ")
    Helpers.send_response(state.socket, "* SEARCH #{seq_list}")
    Helpers.send_response(state.socket, "#{tag} OK SEARCH completed")
    {:continue, state}
  end

  defp handle_fetch(tag, args, state) do
    case Helpers.parse_fetch_args(args) do
      {:ok, sequence_set, items} ->
        messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)
        should_mark_read = Helpers.should_mark_as_read?(items)

        Enum.each(messages, fn {msg, seq_num} ->
          fetch_response =
            Response.build_fetch_response(
              msg,
              seq_num,
              items,
              state.selected_folder,
              state.mailbox.user_id
            )

          Helpers.send_response(state.socket, fetch_response)

          if should_mark_read && !msg.read do
            case Elektrine.Email.get_message(msg.id, state.mailbox.id) do
              nil -> :ok
              full_msg -> Elektrine.Email.mark_as_read(full_msg)
            end
          end
        end)

        Helpers.send_response(state.socket, "#{tag} OK FETCH completed")

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid FETCH arguments")
    end

    {:continue, state}
  end

  defp handle_copy(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, sequence_set, dest_folder} ->
        if destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)

          Enum.each(messages, fn {msg, _seq_num} ->
            copy_message_to_folder(msg, state.mailbox, dest_folder)
          end)

          Helpers.send_response(state.socket, "#{tag} OK COPY completed")
        else
          Helpers.send_response(
            state.socket,
            "#{tag} NO [TRYCREATE] Destination folder not found"
          )
        end

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid COPY arguments")
    end

    {:continue, state}
  end

  defp handle_move(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, sequence_set, dest_folder} ->
        if destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)

          Enum.each(messages, fn {msg, _seq_num} ->
            copy_message_to_folder(msg, state.mailbox, dest_folder)
            current_flags = Response.get_message_flags(msg, state.selected_folder)
            new_flags = ["\\Deleted" | current_flags] |> Enum.uniq()
            update_message_flags(msg, new_flags, state.mailbox)
          end)

          Helpers.send_response(state.socket, "#{tag} OK MOVE completed")
        else
          Helpers.send_response(
            state.socket,
            "#{tag} NO [TRYCREATE] Destination folder not found"
          )
        end

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid MOVE arguments")
    end

    {:continue, state}
  end

  defp handle_store(tag, args, state) do
    case Helpers.parse_store_args(args) do
      {:ok, sequence_set, operation, flags} ->
        messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)

        updated_messages_by_id =
          Enum.reduce(messages, %{}, fn {msg, seq_num}, acc ->
            new_flags =
              Response.apply_flag_operation(msg, operation, flags, state.selected_folder)

            update_message_flags(msg, new_flags, state.mailbox)
            flags_str = Response.format_flags(new_flags)
            Helpers.send_response(state.socket, "* #{seq_num} FETCH (FLAGS (#{flags_str}))")
            Map.put(acc, msg.id, message_updates_from_flags(msg, new_flags))
          end)

        Helpers.send_response(state.socket, "#{tag} OK STORE completed")
        refreshed_state_messages = apply_message_updates(state.messages, updated_messages_by_id)
        {:continue, %{state | messages: refreshed_state_messages}}

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid STORE arguments")
        {:continue, state}
    end
  end

  defp handle_expunge(tag, state) do
    {deleted_indices, remaining_messages} =
      expunge_deleted_messages(state.messages, state.mailbox)

    Enum.each(deleted_indices, fn seq_num ->
      Helpers.send_response(state.socket, "* #{seq_num} EXPUNGE")
    end)

    Helpers.send_response(state.socket, "#{tag} OK EXPUNGE completed")
    {:continue, %{state | messages: remaining_messages}}
  end

  defp handle_check(tag, state) do
    {:ok, fresh_messages} = load_folder_messages(state.mailbox, state.selected_folder)

    if length(fresh_messages) != length(state.messages) do
      Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")
      Helpers.send_response(state.socket, "* #{length(fresh_messages)} RECENT")
    end

    Helpers.send_response(state.socket, "#{tag} OK CHECK completed")
    {:continue, %{state | messages: fresh_messages}}
  end

  defp handle_close(tag, state) do
    {_deleted_indices, _remaining_messages} =
      expunge_deleted_messages(state.messages, state.mailbox)

    Helpers.send_response(state.socket, "#{tag} OK CLOSE completed")
    {:continue, %{state | selected_folder: nil, messages: [], state: :authenticated}}
  end

  defp handle_unselect(tag, state) do
    Helpers.send_response(state.socket, "#{tag} OK UNSELECT completed")
    {:continue, %{state | selected_folder: nil, messages: [], state: :authenticated}}
  end

  defp handle_idle(tag, state) do
    idle_count = count_idle_connections(state.client_ip)

    if idle_count >= @max_idle_per_ip do
      Helpers.send_response(state.socket, "#{tag} NO Too many IDLE connections from your IP")
      {:continue, state}
    else
      session_id = Helpers.generate_session_id()
      track_idle_connection(state.client_ip, session_id)
      Process.put(:imap_idle_session_id, session_id)
      mailbox_topic = "mailbox:#{state.mailbox.id}"
      Phoenix.PubSub.subscribe(Elektrine.PubSub, mailbox_topic)
      Helpers.send_response(state.socket, "+ idling")
      idle_start = System.monotonic_time(:millisecond)
      idle_state = %{state | idle_start: idle_start, idle_session_id: session_id}

      try do
        result =
          case idle_loop(idle_state, idle_start) do
            {:done, new_state} ->
              Helpers.send_response(state.socket, "#{tag} OK IDLE terminated")
              {:continue, %{new_state | idle_start: nil, idle_session_id: nil}}

            {:timeout, new_state} ->
              Helpers.send_response(state.socket, "#{tag} OK IDLE terminated (timeout)")
              {:continue, %{new_state | idle_start: nil, idle_session_id: nil}}
          end

        result
      after
        Phoenix.PubSub.unsubscribe(Elektrine.PubSub, mailbox_topic)
        untrack_idle_connection(state.client_ip, session_id)
        Process.delete(:imap_idle_session_id)
      end
    end
  end

  defp handle_unrecognized(tag, cmd, state) do
    track_invalid_command(state.client_ip, cmd)
    Logger.warning("IMAP unrecognized command from #{state.client_ip}: #{cmd}")
    Helpers.send_response(state.socket, "#{tag} BAD Command not recognized")
    {:continue, state}
  end

  defp handle_uid_fetch(tag, args, state) do
    case Helpers.parse_fetch_args(args) do
      {:ok, uid_set, items} ->
        messages = Helpers.get_messages_by_uid(state.messages, uid_set)
        should_mark_read = Helpers.should_mark_as_read?(items)

        Enum.each(messages, fn {msg, seq_num} ->
          fetch_response =
            Response.build_fetch_response(
              msg,
              seq_num,
              items,
              state.selected_folder,
              state.mailbox.user_id
            )

          Helpers.send_response(state.socket, fetch_response)

          if should_mark_read && !msg.read do
            case Elektrine.Email.get_message(msg.id, state.mailbox.id) do
              nil -> :ok
              full_msg -> Elektrine.Email.mark_as_read(full_msg)
            end
          end
        end)

        Helpers.send_response(state.socket, "#{tag} OK UID FETCH completed")

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid UID FETCH arguments")
    end

    {:continue, state}
  end

  defp handle_uid_search(tag, args, state) do
    criteria = String.upcase(args || "ALL")
    max_sequence = length(state.messages)

    matching_uids =
      state.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {msg, sequence_number} ->
        Helpers.matches_search_criteria?(msg, criteria, sequence_number, max_sequence)
      end)
      |> Enum.map(fn {msg, _sequence_number} -> msg.id end)

    uid_list = Enum.join(matching_uids, " ")
    Helpers.send_response(state.socket, "* SEARCH #{uid_list}")
    Helpers.send_response(state.socket, "#{tag} OK UID SEARCH completed")
    {:continue, state}
  end

  defp handle_uid_copy(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, uid_set, dest_folder} ->
        if destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_uid(state.messages, uid_set)

          Enum.each(messages, fn {msg, _seq_num} ->
            copy_message_to_folder(msg, state.mailbox, dest_folder)
          end)

          Helpers.send_response(state.socket, "#{tag} OK UID COPY completed")
        else
          Helpers.send_response(
            state.socket,
            "#{tag} NO [TRYCREATE] Destination folder not found"
          )
        end

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid UID COPY arguments")
    end

    {:continue, state}
  end

  defp handle_uid_move(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, uid_set, dest_folder} ->
        if destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_uid(state.messages, uid_set)

          if String.upcase(dest_folder) == "TRASH" do
            Enum.each(messages, fn {msg, _seq_num} ->
              current_flags = Response.get_message_flags(msg, state.selected_folder)
              new_flags = ["\\Deleted" | current_flags] |> Enum.uniq()
              update_message_flags(msg, new_flags, state.mailbox)
            end)
          else
            Enum.each(messages, fn {msg, _seq_num} ->
              copy_message_to_folder(msg, state.mailbox, dest_folder)
              current_flags = Response.get_message_flags(msg, state.selected_folder)
              new_flags = ["\\Deleted" | current_flags] |> Enum.uniq()
              update_message_flags(msg, new_flags, state.mailbox)
            end)
          end

          messages
          |> Enum.reverse()
          |> Enum.each(fn {_msg, seq_num} ->
            Helpers.send_response(state.socket, "* #{seq_num} EXPUNGE")
          end)

          Helpers.send_response(state.socket, "#{tag} OK UID MOVE completed")
          {:ok, fresh_messages} = load_folder_messages(state.mailbox, state.selected_folder)
          {:continue, %{state | messages: fresh_messages}}
        else
          Helpers.send_response(
            state.socket,
            "#{tag} NO [TRYCREATE] Destination folder not found"
          )

          {:continue, state}
        end

      {:error, _reason} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid UID MOVE arguments")
        {:continue, state}
    end
  end

  defp handle_uid_expunge(tag, args, state) do
    uid_set = String.trim(args || "")

    messages_to_expunge =
      state.messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {msg, _seq_num} ->
        Helpers.matches_uid_in_set?(msg.id, uid_set) && Map.get(msg, :deleted, false)
      end)

    {expunged_sequence_numbers, remaining_messages} =
      expunge_specific_messages(state.messages, messages_to_expunge, state.mailbox)

    Enum.each(Enum.reverse(expunged_sequence_numbers), fn seq_num ->
      Helpers.send_response(state.socket, "* #{seq_num} EXPUNGE")
    end)

    Helpers.send_response(state.socket, "#{tag} OK UID EXPUNGE completed")
    {:continue, %{state | messages: remaining_messages}}
  end

  defp handle_uid_store(tag, args, state) do
    case Helpers.parse_store_args(args) do
      {:ok, uid_set, operation, flags} ->
        messages = Helpers.get_messages_by_uid(state.messages, uid_set)

        spam_changed =
          Enum.member?(flags, "Junk") or Enum.member?(flags, "$Junk") or
            Enum.member?(flags, "NonJunk") or Enum.member?(flags, "$NonJunk")

        updated_messages_by_id =
          Enum.reduce(messages, %{}, fn {msg, seq_num}, acc ->
            new_flags =
              Response.apply_flag_operation(msg, operation, flags, state.selected_folder)

            update_message_flags(msg, new_flags, state.mailbox)
            flags_str = Response.format_flags(new_flags)

            Helpers.send_response(
              state.socket,
              "* #{seq_num} FETCH (UID #{msg.id} FLAGS (#{flags_str}))"
            )

            Map.put(acc, msg.id, message_updates_from_flags(msg, new_flags))
          end)

        if spam_changed do
          messages
          |> Enum.reverse()
          |> Enum.each(fn {_msg, seq_num} ->
            Helpers.send_response(state.socket, "* #{seq_num} EXPUNGE")
          end)
        end

        Helpers.send_response(state.socket, "#{tag} OK UID STORE completed")

        if spam_changed do
          {:ok, fresh_messages} = load_folder_messages(state.mailbox, state.selected_folder)
          {:continue, %{state | messages: fresh_messages}}
        else
          refreshed_state_messages = apply_message_updates(state.messages, updated_messages_by_id)
          {:continue, %{state | messages: refreshed_state_messages}}
        end

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid UID STORE arguments")
        {:continue, state}
    end
  end

  defp do_authenticate(tag, username, password, state) do
    ip_string = state.client_ip

    case check_auth_rate_limits(ip_string, username) do
      :ok ->
        case authenticate_user(username, password) do
          {:ok, user, mailbox} ->
            Elektrine.IMAP.RateLimiter.clear_attempts(ip_string)
            MailAuthRateLimiter.clear_attempts(:imap, username)
            MailTelemetry.auth(:imap, :success, %{source: :login})

            Helpers.send_response(
              state.socket,
              "#{tag} OK [CAPABILITY #{capability_string(:authenticated)}] Logged in"
            )

            {:continue,
             %{
               state
               | authenticated: true,
                 user: user,
                 username: username,
                 mailbox: mailbox,
                 uid_validity: mailbox.id,
                 state: :authenticated
             }}

          {:error, reason} ->
            Elektrine.IMAP.RateLimiter.record_failure(ip_string)
            MailAuthRateLimiter.record_failure(:imap, username)
            maybe_alert_auth_failure_pressure(ip_string, username)

            Logger.warning(
              "IMAP login failed: user=#{Helpers.redact_email(username)} ip=#{ip_string}"
            )

            MailTelemetry.auth(:imap, :failure, %{reason: reason, source: :login})
            Helpers.send_response(state.socket, "#{tag} NO Authentication failed")
            {:continue, state}
        end

      {:error, {:ip, :rate_limited}} ->
        Logger.warning(
          "IMAP rate limited by IP: ip=#{ip_string} user=#{Helpers.redact_email(username)}"
        )

        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :ip, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO Too many failed attempts")
        :timer.sleep(1000)
        {:logout, state}

      {:error, {:ip, :blocked}} ->
        Logger.warning("IMAP blocked IP: ip=#{ip_string} user=#{Helpers.redact_email(username)}")
        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :ip_blocked, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO IP temporarily blocked")
        {:logout, state}

      {:error, {:account, :rate_limited}} ->
        Logger.warning(
          "IMAP rate limited by account key: ip=#{ip_string} user=#{Helpers.redact_email(username)}"
        )

        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :account, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO Too many failed attempts")
        :timer.sleep(1000)
        {:logout, state}

      {:error, {:account, :blocked}} ->
        Logger.warning(
          "IMAP blocked account key: ip=#{ip_string} user=#{Helpers.redact_email(username)}"
        )

        MailTelemetry.auth(:imap, :rate_limited, %{ratelimit: :account_blocked, source: :login})
        Helpers.send_response(state.socket, "#{tag} NO Account temporarily blocked")
        {:logout, state}
    end
  end

  defp check_auth_rate_limits(ip_string, username) do
    case Elektrine.IMAP.RateLimiter.check_attempt(ip_string) do
      {:ok, _attempts_left} ->
        case MailAuthRateLimiter.check_attempt(:imap, username) do
          {:ok, _remaining} -> :ok
          {:error, reason} -> {:error, {:account, reason}}
        end

      {:error, reason} ->
        {:error, {:ip, reason}}
    end
  end

  defp maybe_alert_auth_failure_pressure(ip_string, username) do
    ip_failures =
      Elektrine.IMAP.RateLimiter.get_status(ip_string) |> get_in([:attempts, 60, :count]) || 0

    account_failures = MailAuthRateLimiter.failure_count(:imap, username)

    if ip_failures >= 4 or account_failures >= 4 do
      Logger.warning(
        "IMAP auth failure spike: ip=#{ip_string} ip_failures=#{ip_failures} account_failures=#{account_failures}"
      )
    end
  end

  defp authenticate_user(username, password) do
    case Elektrine.Accounts.authenticate_with_app_password(username, password) do
      {:ok, user} ->
        Elektrine.Accounts.record_imap_access(user.id)

        case get_or_create_mailbox(user) do
          {:ok, mailbox} -> {:ok, user, mailbox}
          _ -> {:error, :mailbox_error}
        end

      {:error, {:invalid_token, user}} ->
        try_regular_password_auth(user, password)

      {:error, :user_not_found} ->
        {:error, :authentication_failed}
    end
  end

  defp try_regular_password_auth(user, password) do
    if has_2fa_enabled?(user) do
      {:error, :requires_app_password}
    else
      case Elektrine.Accounts.verify_user_password(user, password) do
        {:ok, _user} ->
          Elektrine.Accounts.record_imap_access(user.id)

          case get_or_create_mailbox(user) do
            {:ok, mailbox} -> {:ok, user, mailbox}
            _ -> {:error, :mailbox_error}
          end

        {:error, _} ->
          {:error, :authentication_failed}
      end
    end
  end

  defp has_2fa_enabled?(user) do
    user.two_factor_enabled == true
  end

  defp get_or_create_mailbox(user) do
    case Elektrine.Email.ensure_user_has_mailbox(user) do
      {:ok, mailbox} -> {:ok, mailbox}
      _ -> {:error, :mailbox_error}
    end
  end

  defp load_folder_messages(mailbox, folder) do
    folder_normalized = String.upcase(folder)

    messages =
      case folder_normalized do
        "INBOX" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :inbox)
        "SENT" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :sent)
        "DRAFTS" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :drafts)
        "TRASH" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :trash)
        "SPAM" -> Elektrine.Email.list_messages_for_imap(mailbox.id, :spam)
        _ -> load_custom_folder_messages(mailbox, folder)
      end

    {:ok, messages}
  end

  defp load_custom_folder_messages(%{user_id: nil}, _folder_name) do
    []
  end

  defp load_custom_folder_messages(mailbox, folder_name) do
    case find_custom_folder_by_name(mailbox.user_id, folder_name) do
      nil -> []
      folder -> Elektrine.Email.list_messages_for_imap_custom_folder(mailbox.id, folder.id)
    end
  end

  defp update_message_flags(msg, flags, mailbox) do
    updates = message_updates_from_flags(msg, flags)

    case Elektrine.Email.update_message_flags(msg.id, mailbox.id, updates) do
      {:ok, _updated} ->
        :ok

      {:error, :not_found} ->
        Logger.error("Access denied: message #{msg.id} does not belong to mailbox #{mailbox.id}")
        :error

      {:error, reason} ->
        Logger.error("Failed to update message #{msg.id} flags: #{inspect(reason)}")
        :error
    end
  end

  defp message_updates_from_flags(msg, flags) do
    spam =
      cond do
        Enum.member?(flags, "Junk") || Enum.member?(flags, "$Junk") -> true
        Enum.member?(flags, "NonJunk") || Enum.member?(flags, "$NonJunk") -> false
        true -> Map.get(msg, :spam, false)
      end

    is_draft = Enum.member?(flags, "\\Draft")
    current_status = Map.get(msg, :status, "received")

    new_status =
      cond do
        is_draft -> "draft"
        current_status == "draft" && !is_draft -> "received"
        true -> current_status
      end

    %{
      read: Enum.member?(flags, "\\Seen"),
      flagged: Enum.member?(flags, "\\Flagged"),
      answered: Enum.member?(flags, "\\Answered"),
      deleted: Enum.member?(flags, "\\Deleted"),
      spam: spam,
      status: new_status
    }
  end

  defp apply_message_updates(messages, updates_by_id) do
    Enum.map(messages, fn msg ->
      case Map.get(updates_by_id, msg.id) do
        nil -> msg
        updates -> Map.merge(msg, updates)
      end
    end)
  end

  defp expunge_deleted_messages(messages, mailbox) do
    deleted_with_sequence =
      messages
      |> Enum.with_index(1)
      |> Enum.filter(fn {msg, _sequence_number} -> msg.deleted || false end)

    deleted = Enum.map(deleted_with_sequence, fn {msg, _sequence_number} -> msg end)

    deleted_sequence_numbers =
      Enum.map(deleted_with_sequence, fn {_msg, sequence_number} -> sequence_number end)

    remaining = Enum.reject(messages, fn msg -> msg.deleted || false end)
    Enum.each(deleted, fn msg -> Elektrine.Email.delete_message(msg.id, mailbox.id) end)

    expunge_sequence_numbers =
      deleted_sequence_numbers
      |> Enum.with_index()
      |> Enum.map(fn {sequence_number, removed_before} -> sequence_number - removed_before end)

    {expunge_sequence_numbers, remaining}
  end

  defp expunge_specific_messages(all_messages, messages_to_expunge, mailbox) do
    uids_to_expunge =
      Enum.map(messages_to_expunge, fn {msg, _seq_num} -> msg.id end) |> MapSet.new()

    sequence_numbers = Enum.map(messages_to_expunge, fn {_msg, seq_num} -> seq_num end)

    Enum.each(messages_to_expunge, fn {msg, _seq_num} ->
      Elektrine.Email.delete_message(msg.id, mailbox.id)
    end)

    remaining = Enum.reject(all_messages, fn msg -> MapSet.member?(uids_to_expunge, msg.id) end)
    {sequence_numbers, remaining}
  end

  defp copy_message_to_folder(msg, mailbox, dest_folder) do
    case Elektrine.Email.get_message(msg.id, mailbox.id) do
      nil ->
        Logger.error("Cannot copy message #{msg.id}: message not found or access denied")
        {:error, :not_found}

      full_msg ->
        case resolve_destination_folder(dest_folder, mailbox.user_id, full_msg) do
          {:ok, destination} ->
            message_attrs = %{
              message_id: "copy-#{System.system_time(:millisecond)}-#{full_msg.message_id}",
              from: full_msg.from,
              to: full_msg.to,
              cc: full_msg.cc,
              bcc: full_msg.bcc,
              subject: full_msg.subject,
              text_body: full_msg.text_body,
              html_body: full_msg.html_body,
              status: destination.status,
              read: full_msg.read,
              spam: destination.spam,
              archived: destination.archived,
              deleted: destination.deleted,
              flagged: full_msg.flagged,
              metadata: full_msg.metadata,
              mailbox_id: mailbox.id,
              attachments: full_msg.attachments,
              has_attachments: full_msg.has_attachments,
              folder_id: destination.folder_id
            }

            case Elektrine.Email.create_message(message_attrs) do
              {:ok, new_msg} ->
                Phoenix.PubSub.broadcast(
                  Elektrine.PubSub,
                  "mailbox:#{mailbox.id}",
                  {:new_email, new_msg}
                )

                :ok

              {:error, reason} ->
                Logger.error("Failed to copy message #{msg.id}: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, :invalid_folder} ->
            Logger.warning("Cannot copy message #{msg.id}: destination folder not found")
            {:error, :invalid_folder}
        end
    end
  end

  defp resolve_destination_folder(dest_folder, mailbox_user_id, full_msg) do
    case String.upcase(dest_folder) do
      "INBOX" ->
        {:ok, %{status: "received", spam: false, deleted: false, archived: false, folder_id: nil}}

      "SENT" ->
        {:ok, %{status: "sent", spam: false, deleted: false, archived: false, folder_id: nil}}

      "DRAFTS" ->
        {:ok, %{status: "draft", spam: false, deleted: false, archived: false, folder_id: nil}}

      "TRASH" ->
        {:ok,
         %{status: full_msg.status, spam: false, deleted: true, archived: false, folder_id: nil}}

      "SPAM" ->
        {:ok,
         %{status: full_msg.status, spam: true, deleted: false, archived: false, folder_id: nil}}

      _custom_or_unknown ->
        folder =
          if mailbox_user_id do
            find_custom_folder_by_name(mailbox_user_id, dest_folder)
          else
            nil
          end

        if folder do
          {:ok,
           %{
             status: full_msg.status,
             spam: full_msg.spam,
             deleted: false,
             archived: full_msg.archived,
             folder_id: folder.id
           }}
        else
          {:error, :invalid_folder}
        end
    end
  end

  defp receive_literal_data(socket, size) do
    if size > @max_message_size do
      {:error, :message_too_large}
    else
      :inet.setopts(socket, packet: :raw, active: false)

      result =
        try do
          receive_literal_chunks(socket, size, <<>>, 0)
        rescue
          e ->
            Logger.error("IMAP APPEND: Exception during receive: #{inspect(e)}")
            {:error, :receive_exception}
        after
          :inet.setopts(socket, packet: :line, active: false)
        end

      result
    end
  end

  defp receive_literal_chunks(socket, total_size, acc, received_so_far) do
    remaining = total_size - received_so_far

    if remaining <= 0 do
      case :gen_tcp.recv(socket, 2, 5000) do
        {:ok, data} when data == "\r\n" or data == ~c"\r\n" ->
          {:ok, to_string(acc)}

        {:ok, other} ->
          other_bin =
            if is_list(other) do
              :erlang.list_to_binary(other)
            else
              other
            end

          if other_bin == "\r\n" do
            {:ok, to_string(acc)}
          else
            {:ok, to_string(acc)}
          end

        {:error, _reason} ->
          {:ok, to_string(acc)}
      end
    else
      chunk_size = min(remaining, 65_536)

      case :gen_tcp.recv(socket, chunk_size, 60_000) do
        {:ok, chunk_raw} ->
          chunk =
            if is_list(chunk_raw) do
              :erlang.list_to_binary(chunk_raw)
            else
              chunk_raw
            end

          new_acc = acc <> chunk
          new_received = received_so_far + byte_size(chunk)
          receive_literal_chunks(socket, total_size, new_acc, new_received)

        {:error, reason} ->
          Logger.error("IMAP APPEND: Receive error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp store_append_message(mailbox, folder, data) do
    {headers, body} =
      try do
        parse_email_data(data)
      rescue
        e ->
          Logger.error("IMAP APPEND: Email parsing failed: #{inspect(e)}")
          {%{"subject" => "(Parse Error)", "from" => "", "to" => ""}, ""}
      end

    raw_subject = Map.get(headers, "subject", "(No Subject)")
    subject = Elektrine.Email.Receiver.decode_mail_header(raw_subject)

    if subject == "(Parse Error)" do
      {:error, :parse_error}
    else
      folder_clean = String.trim(folder)
      folder_lower = String.downcase(folder_clean)

      custom_folder_id =
        cond do
          folder_lower in ["inbox", "sent", "drafts", "trash", "spam"] ->
            nil

          is_integer(mailbox.user_id) ->
            case find_custom_folder_by_name(mailbox.user_id, folder_clean) do
              nil -> nil
              custom_folder -> custom_folder.id
            end

          true ->
            nil
        end

      if folder_lower not in ["inbox", "sent", "drafts", "trash", "spam"] &&
           is_nil(custom_folder_id) do
        {:error, :unknown_folder}
      else
        status =
          case folder_lower do
            "drafts" -> "draft"
            "sent" -> "sent"
            _ -> "received"
          end

        from_value =
          headers |> Map.get("from", "") |> Elektrine.Email.Receiver.decode_mail_header()

        to_value = headers |> Map.get("to", "") |> Elektrine.Email.Receiver.decode_mail_header()

        category =
          if status == "sent" do
            nil
          else
            "inbox"
          end

        message_attrs = %{
          message_id:
            Map.get(headers, "message-id", "append-#{System.system_time(:millisecond)}"),
          from: from_value,
          to: to_value,
          subject: subject,
          text_body: extract_text_body_internal(body, headers),
          status: status,
          category: category,
          mailbox_id: mailbox.id,
          folder_id: custom_folder_id,
          read: true
        }

        message_attrs =
          if Map.has_key?(headers, "cc") and headers["cc"] do
            cc_decoded = Elektrine.Email.Receiver.decode_mail_header(headers["cc"])
            Map.put(message_attrs, :cc, cc_decoded)
          else
            message_attrs
          end

        message_attrs =
          if Map.has_key?(headers, "bcc") and headers["bcc"] do
            bcc_decoded = Elektrine.Email.Receiver.decode_mail_header(headers["bcc"])
            Map.put(message_attrs, :bcc, bcc_decoded)
          else
            message_attrs
          end

        message_attrs =
          if html = extract_html_body_internal(body, headers) do
            Map.put(message_attrs, :html_body, html)
          else
            message_attrs
          end

        existing = Elektrine.Email.get_message_by_id(message_attrs.message_id, mailbox.id)

        if existing do
          {:ok, existing}
        else
          message_attrs =
            case extract_attachments_internal(body, headers) do
              attachments when map_size(attachments) > 0 ->
                validated_attachments = validate_extracted_attachments(attachments)

                updated_html =
                  replace_cid_with_data_urls(message_attrs[:html_body], validated_attachments)

                message_attrs
                |> Map.put(:attachments, validated_attachments)
                |> Map.put(:has_attachments, map_size(validated_attachments) > 0)
                |> Map.put(:html_body, updated_html)

              _ ->
                message_attrs
            end

          case Elektrine.Email.create_message(message_attrs) do
            {:ok, message} ->
              Phoenix.PubSub.broadcast(
                Elektrine.PubSub,
                "mailbox:#{mailbox.id}",
                {:new_email, message}
              )

              {:ok, message}

            {:error, changeset} ->
              Logger.error("IMAP APPEND: Failed to create message: #{inspect(changeset.errors)}")
              {:error, changeset}
          end
        end
      end
    end
  end

  def parse_email_data(data) do
    message = Mail.Parsers.RFC2822.parse(data)

    headers =
      message.headers
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), stringify_header_value(v)} end)

    body = message.body || ""
    {headers, body}
  rescue
    e in MatchError ->
      data_preview = String.slice(data, 0, 200)
      Logger.error("Failed to parse email data. Preview: #{inspect(data_preview)}")
      Logger.error("Parse error: #{inspect(e)}")
      {%{"subject" => "(Parse Error)", "from" => "", "to" => ""}, data}
  end

  defp stringify_header_value(value) when is_binary(value) do
    value
  end

  defp stringify_header_value({name, email}) when is_binary(name) and is_binary(email) do
    if name && String.trim(name) != "" do
      "#{name} <#{email}>"
    else
      email
    end
  end

  defp stringify_header_value({email}) when is_binary(email) do
    email
  end

  defp stringify_header_value([first | _rest]) when is_binary(first) do
    first
  end

  defp stringify_header_value([first | rest]) when is_tuple(first) do
    [first | rest] |> Enum.map_join(", ", &stringify_header_value/1)
  end

  defp stringify_header_value(value) when is_list(value) do
    inspect(value)
  end

  defp stringify_header_value(value) when is_tuple(value) do
    inspect(value)
  end

  defp stringify_header_value(value) do
    to_string(value)
  end

  def extract_text_body(_body, _headers, message \\ nil) do
    if message do
      case Mail.get_text(message) do
        %Mail.Message{body: text_body} -> text_body
        nil -> nil
      end
    else
      nil
    end
  end

  def extract_html_body(_body, _headers, message \\ nil) do
    if message do
      case Mail.get_html(message) do
        %Mail.Message{body: html_body} -> html_body
        nil -> nil
      end
    else
      nil
    end
  end

  def extract_attachments(_body, _headers, message \\ nil) do
    if message do
      extract_attachments_from_message(message)
    else
      %{}
    end
  end

  defp extract_attachments_from_message(message) do
    {attachments, _counter} = walk_parts(message, %{}, 0)
    attachments
  end

  defp walk_parts(%Mail.Message{multipart: true, parts: parts}, acc, counter) do
    Enum.reduce(parts, {acc, counter}, fn part, {inner_acc, inner_counter} ->
      walk_parts(part, inner_acc, inner_counter)
    end)
  end

  defp walk_parts(%Mail.Message{} = message, acc, counter) do
    if Mail.Message.is_attachment?(message) do
      filename = get_attachment_filename(message)
      content_type = get_content_type(message)

      attachment_map = %{
        "filename" => filename,
        "content_type" => content_type,
        "data" => message.body || "",
        "size" =>
          if message.body do
            byte_size(message.body)
          else
            0
          end
      }

      attachment_map =
        case Mail.Message.get_header(message, :content_id) do
          nil -> attachment_map
          cid -> Map.put(attachment_map, "content_id", String.trim(cid, "<>"))
        end

      {Map.put(acc, "#{counter}_#{filename}", attachment_map), counter + 1}
    else
      {acc, counter}
    end
  end

  defp get_attachment_filename(message) do
    case Mail.Message.get_header(message, :content_disposition) do
      nil ->
        "attachment_#{:rand.uniform(10_000)}"

      disposition when is_list(disposition) ->
        Enum.find_value(disposition, fn
          {"filename", filename} when is_binary(filename) -> filename
          _ -> nil
        end) || "attachment_#{:rand.uniform(10_000)}"

      disposition when is_binary(disposition) ->
        case Regex.run(~r/filename[*]?=\s*"?([^";]+)"?/i, disposition) do
          [_, filename] -> filename
          _ -> "attachment_#{:rand.uniform(10_000)}"
        end

      _ ->
        "attachment_#{:rand.uniform(10_000)}"
    end
  end

  defp get_content_type(message) do
    case Mail.Message.get_content_type(message) do
      [type | _] when is_binary(type) -> type
      [type, _ | _] when is_binary(type) -> type
      _ -> "application/octet-stream"
    end
  end

  defp extract_text_body_internal(body, _headers) do
    if String.contains?(body, "Content-Type: text/plain") do
      body
      |> String.split(~r/Content-Type: text\/plain/i, parts: 2)
      |> List.last()
      |> String.split("\n\n", parts: 2)
      |> List.last()
      |> String.split(~r/--[a-zA-Z0-9_-]+--?/, parts: 2)
      |> List.first()
      |> String.trim()
    else
      body
    end
  end

  defp extract_html_body_internal(body, _headers) do
    if String.contains?(body, "Content-Type: text/html") do
      body
      |> String.split(~r/Content-Type: text\/html/i, parts: 2)
      |> List.last()
      |> String.split("\n\n", parts: 2)
      |> List.last()
      |> String.split(~r/--[a-zA-Z0-9_-]+--?/, parts: 2)
      |> List.first()
      |> String.trim()
    else
      nil
    end
  end

  defp extract_attachments_internal(body, headers) do
    content_type = Map.get(headers, "content-type", "")

    case Regex.run(~r/boundary[=:]?\s*"?([^"\s;]+)"?/i, content_type) do
      [_, boundary] ->
        parts = String.split(body, "--#{boundary}")

        {attachments, _idx} =
          parts
          |> Enum.reduce({%{}, 0}, fn part, {acc, counter} ->
            extract_attachments_from_part(part, acc, counter)
          end)

        attachments

      _ ->
        %{}
    end
  end

  defp extract_attachments_from_part(part, acc, counter) do
    case parse_mime_part(part) do
      {:attachment, filename, content_type, data, encoding, cid} ->
        attachment_map = %{
          "filename" => filename,
          "content_type" => content_type,
          "data" => data,
          "size" => byte_size(data)
        }

        attachment_map =
          if encoding do
            Map.put(attachment_map, "encoding", encoding)
          else
            attachment_map
          end

        attachment_map =
          if cid do
            Map.put(attachment_map, "content_id", cid)
          else
            attachment_map
          end

        {Map.put(acc, "#{counter}_#{filename}", attachment_map), counter + 1}

      {:multipart, nested_boundary, nested_content} ->
        nested_parts = String.split(nested_content, "--#{nested_boundary}")

        Enum.reduce(nested_parts, {acc, counter}, fn nested_part, {inner_acc, inner_counter} ->
          extract_attachments_from_part(nested_part, inner_acc, inner_counter)
        end)

      _ ->
        {acc, counter}
    end
  end

  defp parse_mime_part(part) do
    case String.split(part, ~r/\r?\n\r?\n/, parts: 2) do
      [part_headers_str, content] ->
        part_headers = parse_part_headers(part_headers_str)
        content_disposition = Map.get(part_headers, "content-disposition", "")
        content_type = Map.get(part_headers, "content-type", "")
        content_id = Map.get(part_headers, "content-id", "")
        is_multipart = String.contains?(content_type, "multipart/")

        if is_multipart do
          case Regex.run(~r/boundary[=:]?\s*"?([^"\s;]+)"?/i, content_type) do
            [_, nested_boundary] -> {:multipart, nested_boundary, content}
            _ -> :not_attachment
          end
        else
          is_text_part =
            String.contains?(content_type, "text/plain") or
              String.contains?(content_type, "text/html")

          is_attachment =
            String.contains?(content_disposition, "attachment") or
              String.contains?(content_disposition, "inline") or
              (content_id != "" and String.contains?(content_type, "image"))

          if !is_text_part and is_attachment and String.trim(content) != "" do
            filename =
              extract_filename(content_disposition, content_type) ||
                "attachment_#{:rand.uniform(10_000)}"

            is_base64 = String.contains?(part_headers_str, "base64")

            clean_content =
              if is_base64 do
                String.replace(content, ~r/\s/, "")
              else
                String.trim(content)
              end

            encoding =
              if is_base64 do
                "base64"
              else
                nil
              end

            cid =
              if content_id != "" do
                content_id |> String.trim_leading("<") |> String.trim_trailing(">")
              else
                nil
              end

            {:attachment, filename, content_type, clean_content, encoding, cid}
          else
            :not_attachment
          end
        end

      _ ->
        :not_attachment
    end
  end

  defp parse_part_headers(headers_str) do
    headers_str
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({%{}, nil}, fn line, {acc, current_header} ->
      cond do
        String.match?(line, ~r/^[A-Za-z-]+:/) ->
          case String.split(line, ":", parts: 2) do
            [name, value] ->
              key = String.downcase(String.trim(name))
              val = String.trim(value)
              {Map.put(acc, key, val), key}

            _ ->
              {acc, current_header}
          end

        String.match?(line, ~r/^\s/) and current_header != nil ->
          current_value = Map.get(acc, current_header, "")
          new_value = current_value <> " " <> String.trim(line)
          {Map.put(acc, current_header, new_value), current_header}

        true ->
          {acc, current_header}
      end
    end)
    |> elem(0)
  end

  defp extract_filename(content_disposition, content_type) do
    case Regex.run(~r/filename\s*=\s*"([^"]+)"/i, content_disposition) do
      [_, filename] ->
        filename

      _ ->
        case Regex.run(~r/filename\s*=\s*([^\s;]+)/i, content_disposition) do
          [_, filename] ->
            filename

          _ ->
            case Regex.run(~r/name\s*=\s*"([^"]+)"/i, content_type) do
              [_, filename] ->
                filename

              _ ->
                case Regex.run(~r/name\s*=\s*([^\s;]+)/i, content_type) do
                  [_, filename] -> filename
                  _ -> nil
                end
            end
        end
    end
  end

  defp validate_extracted_attachments(attachments) do
    allowed_types = [
      "image/jpeg",
      "image/png",
      "image/gif",
      "image/webp",
      "application/pdf",
      "application/msword",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "application/vnd.ms-excel",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "text/plain"
    ]

    attachments
    |> Enum.filter(fn {_key, attachment} ->
      content_type = attachment["content_type"] || ""
      filename = attachment["filename"] || ""

      dangerous_extensions = [
        ".exe",
        ".bat",
        ".sh",
        ".cmd",
        ".com",
        ".scr",
        ".vbs",
        ".js",
        ".jar",
        ".app",
        ".dmg",
        ".apk",
        ".msi",
        ".php",
        ".py",
        ".rb",
        ".zip",
        ".tar",
        ".gz",
        ".7z",
        ".rar"
      ]

      has_dangerous_ext =
        Enum.any?(dangerous_extensions, fn ext ->
          String.ends_with?(String.downcase(filename), ext)
        end)

      type_allowed =
        Enum.any?(allowed_types, fn allowed -> String.starts_with?(content_type, allowed) end)

      cond do
        has_dangerous_ext ->
          Logger.warning("IMAP: Blocked dangerous attachment: #{filename} (#{content_type})")
          false

        not type_allowed ->
          Logger.warning(
            "IMAP: Blocked non-allowed attachment type: #{filename} (#{content_type})"
          )

          false

        true ->
          true
      end
    end)
    |> Enum.into(%{})
  end

  defp replace_cid_with_data_urls(nil, _attachments) do
    nil
  end

  defp replace_cid_with_data_urls(html_body, attachments) do
    Enum.reduce(attachments, html_body, fn {_attachment_id, attachment}, html ->
      if attachment["content_id"] do
        raw_data =
          case attachment do
            %{"storage_type" => "s3"} ->
              case AttachmentStorage.download_attachment(attachment) do
                {:ok, content} -> content
                {:error, _} -> attachment["data"]
              end

            _ ->
              attachment["data"]
          end

        if raw_data do
          data =
            if attachment["encoding"] == "base64" do
              case Base.decode64(raw_data, ignore: :whitespace) do
                {:ok, decoded} -> decoded
                :error -> raw_data
              end
            else
              raw_data
            end

          content_type = attachment["content_type"] || "application/octet-stream"
          clean_content_type = content_type |> String.split(";") |> List.first() |> String.trim()
          base64_data = Base.encode64(data)
          data_url = "data:#{clean_content_type};base64,#{base64_data}"
          cid_pattern = "cid:#{attachment["content_id"]}"
          String.replace(html, cid_pattern, data_url)
        else
          html
        end
      else
        html
      end
    end)
  end

  defp idle_loop(state, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    timeout = max(1000, @idle_timeout_ms - elapsed)
    :inet.setopts(state.socket, active: :once)

    receive do
      {:tcp, _socket, data} ->
        command = data |> to_string() |> String.trim() |> String.upcase()
        :inet.setopts(state.socket, active: false)

        if command == "DONE" do
          {:done, state}
        else
          idle_loop(state, start_time)
        end

      {:tcp_closed, _socket} ->
        {:done, state}

      {:tcp_error, _socket, reason} ->
        Logger.error("IDLE socket error: #{inspect(reason)}")
        {:done, state}

      {:new_email, message} ->
        if should_notify_idle_folder_update?(message, state.selected_folder) do
          {:ok, fresh_messages} = load_folder_messages(state.mailbox, state.selected_folder)

          if length(fresh_messages) != length(state.messages) do
            Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")
            Helpers.send_response(state.socket, "* #{length(fresh_messages)} RECENT")
          end

          updated_state = %{state | messages: fresh_messages}
          idle_loop(updated_state, start_time)
        else
          idle_loop(state, start_time)
        end
    after
      timeout ->
        :inet.setopts(state.socket, active: false)
        {:timeout, state}
    end
  end

  defp count_idle_connections(ip) do
    if :ets.whereis(:imap_idle_connections) != :undefined do
      case :ets.lookup(:imap_idle_connections, ip) do
        [{^ip, sessions}] ->
          active_sessions = persist_active_idle_sessions(ip, sessions)
          length(active_sessions)

        [] ->
          0
      end
    else
      0
    end
  end

  defp track_idle_connection(ip, session_id) do
    if :ets.whereis(:imap_idle_connections) != :undefined do
      now = System.monotonic_time(:millisecond)

      sessions =
        case :ets.lookup(:imap_idle_connections, ip) do
          [{^ip, existing}] ->
            existing
            |> normalize_idle_sessions(now)
            |> Enum.reject(fn {existing_session_id, _started_at} ->
              existing_session_id == session_id
            end)
            |> then(&[{session_id, now} | &1])

          [] ->
            [{session_id, now}]
        end

      :ets.insert(:imap_idle_connections, {ip, sessions})
    end
  end

  defp untrack_idle_connection(ip, session_id) do
    if :ets.whereis(:imap_idle_connections) != :undefined do
      case :ets.lookup(:imap_idle_connections, ip) do
        [{^ip, sessions}] ->
          new_sessions =
            sessions
            |> normalize_idle_sessions(System.monotonic_time(:millisecond))
            |> Enum.reject(fn {existing_session_id, _started_at} ->
              existing_session_id == session_id
            end)

          if new_sessions == [] do
            :ets.delete(:imap_idle_connections, ip)
          else
            :ets.insert(:imap_idle_connections, {ip, new_sessions})
          end

        [] ->
          :ok
      end
    end
  end

  defp persist_active_idle_sessions(ip, sessions) do
    now = System.monotonic_time(:millisecond)

    active_sessions =
      sessions
      |> normalize_idle_sessions(now)
      |> Enum.reject(fn {_session_id, started_at} ->
        now - started_at > @idle_timeout_ms + @idle_stale_grace_ms
      end)

    if active_sessions == [] do
      :ets.delete(:imap_idle_connections, ip)
    else
      :ets.insert(:imap_idle_connections, {ip, active_sessions})
    end

    active_sessions
  end

  defp normalize_idle_sessions(sessions, now) do
    Enum.map(sessions, fn
      {session_id, started_at} when is_integer(started_at) -> {session_id, started_at}
      session_id -> {session_id, now}
    end)
  end

  defp should_notify_idle_folder_update?(message, selected_folder) do
    if system_folder_name?(selected_folder || "") do
      Helpers.message_in_current_folder?(message, selected_folder)
    else
      true
    end
  end

  defp track_invalid_command(ip, _command) do
    if :ets.whereis(:imap_invalid_commands) != :undefined do
      now = System.system_time(:second)
      table_size = :ets.info(:imap_invalid_commands, :size)
      max_tracked_ips = 10_000

      if table_size >= max_tracked_ips do
        cleanup_old_invalid_command_entries(now)
      end

      {count, first_seen} =
        case :ets.lookup(:imap_invalid_commands, ip) do
          [{^ip, c, t}] -> {c + 1, t}
          [] -> {1, now}
        end

      :ets.insert(:imap_invalid_commands, {ip, count, first_seen})

      if count >= 5 do
        Logger.error(
          "SECURITY ALERT: Possible port scanner detected from #{ip} - #{count} invalid commands in #{now - first_seen}s"
        )
      end

      count
    else
      0
    end
  end

  defp cleanup_old_invalid_command_entries(now) do
    if :ets.whereis(:imap_invalid_commands) != :undefined do
      cutoff = now - 3600

      :ets.foldl(
        fn {ip, _count, first_seen}, acc ->
          if first_seen < cutoff do
            :ets.delete(:imap_invalid_commands, ip)
          end

          acc
        end,
        nil,
        :imap_invalid_commands
      )
    end
  end
end
