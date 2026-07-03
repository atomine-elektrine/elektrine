defmodule Elektrine.IMAP.Commands.Message do
  @moduledoc "IMAP message commands (FETCH, STORE, COPY, MOVE, EXPUNGE, CHECK, CLOSE, UNSELECT) and the UID dispatcher."

  require Logger

  alias Elektrine.IMAP.Commands.Search
  alias Elektrine.IMAP.Commands.Shared
  alias Elektrine.IMAP.{Folders, Helpers, RecentState, Response}

  def handle_uid(tag, args, state) do
    case String.split(args || "", " ", parts: 2) do
      [subcommand, subargs] ->
        case String.upcase(subcommand) do
          "FETCH" ->
            handle_uid_fetch(tag, subargs, state)

          "STORE" ->
            handle_uid_store(tag, subargs, state)

          "SEARCH" ->
            Search.handle_uid_search(tag, subargs, state)

          "COPY" ->
            handle_uid_copy(tag, subargs, state)

          "MOVE" ->
            handle_uid_move(tag, subargs, state)

          "EXPUNGE" ->
            handle_uid_expunge(tag, subargs, state)

          "SORT" ->
            Search.handle_uid_sort(tag, subargs, state)

          "THREAD" ->
            Search.handle_uid_thread(tag, subargs, state)

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

  def handle_fetch(tag, args, state) do
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

  def handle_copy(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, sequence_set, dest_folder} ->
        if Folders.destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)
          uid_pairs = copy_uid_pairs(messages, state.mailbox, dest_folder)
          send_tagged_ok_with_optional_copyuid(state, tag, uid_pairs, "COPY completed")
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

  def handle_move(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, sequence_set, dest_folder} ->
        if Folders.destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)

          uid_pairs =
            if String.upcase(dest_folder) == "TRASH" do
              []
            else
              copy_uid_pairs(messages, state.mailbox, dest_folder)
            end

          Enum.each(messages, fn {msg, _seq_num} ->
            current_flags = Response.get_message_flags(msg, state.selected_folder)
            new_flags = ["\\Deleted" | current_flags] |> Enum.uniq()
            update_message_flags(msg, new_flags, state.mailbox)
          end)

          send_tagged_ok_with_optional_copyuid(state, tag, uid_pairs, "MOVE completed")
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

  defp handle_uid_copy(tag, args, state) do
    case Helpers.parse_copy_args(args) do
      {:ok, uid_set, dest_folder} ->
        if Folders.destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_uid(state.messages, uid_set)
          uid_pairs = copy_uid_pairs(messages, state.mailbox, dest_folder)
          send_tagged_ok_with_optional_copyuid(state, tag, uid_pairs, "UID COPY completed")
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
        if Folders.destination_folder_exists?(dest_folder, state.user.id) do
          messages = Helpers.get_messages_by_uid(state.messages, uid_set)

          uid_pairs =
            if String.upcase(dest_folder) == "TRASH" do
              []
            else
              copy_uid_pairs(messages, state.mailbox, dest_folder)
            end

          Enum.each(messages, fn {msg, _seq_num} ->
            current_flags = Response.get_message_flags(msg, state.selected_folder)
            new_flags = ["\\Deleted" | current_flags] |> Enum.uniq()
            update_message_flags(msg, new_flags, state.mailbox)
          end)

          messages
          |> Enum.reverse()
          |> Enum.each(fn {_msg, seq_num} ->
            Helpers.send_response(state.socket, "* #{seq_num} EXPUNGE")
          end)

          send_tagged_ok_with_optional_copyuid(state, tag, uid_pairs, "UID MOVE completed")

          {:ok, fresh_messages} =
            Shared.load_folder_messages(state.mailbox, state.selected_folder)

          {:continue,
           Map.merge(state, %{
             messages: fresh_messages,
             recent_message_ids:
               RecentState.trim_recent_message_ids(
                 fresh_messages,
                 Map.get(state, :recent_message_ids, MapSet.new())
               )
           })}
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

  defp copy_uid_pairs(messages, mailbox, dest_folder) do
    messages
    |> Enum.reduce([], fn {msg, _seq_num}, acc ->
      case copy_message_to_folder(msg, mailbox, dest_folder) do
        {:ok, new_uid} -> [{msg.id, new_uid} | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp send_tagged_ok_with_optional_copyuid(state, tag, uid_pairs, completion_text) do
    case copyuid_response_code(state.uid_validity, uid_pairs) do
      nil ->
        Helpers.send_response(state.socket, "#{tag} OK #{completion_text}")

      copyuid_code ->
        Helpers.send_response(state.socket, "#{tag} OK #{copyuid_code} #{completion_text}")
    end
  end

  defp copyuid_response_code(_uid_validity, []), do: nil

  defp copyuid_response_code(uid_validity, uid_pairs) do
    {source_uids, destination_uids} = Enum.unzip(uid_pairs)
    source_set = format_uid_set(source_uids)
    destination_set = format_uid_set(destination_uids)
    "[COPYUID #{uid_validity} #{source_set} #{destination_set}]"
  end

  defp format_uid_set(uids) do
    Enum.map_join(uids, ",", &to_string/1)
  end

  def handle_store(tag, args, state) do
    case Helpers.parse_store_args(args) do
      {:ok, sequence_set, operation, flags} ->
        messages = Helpers.get_messages_by_sequence(state.messages, sequence_set)

        updated_messages_by_id =
          Enum.reduce(messages, %{}, fn {msg, seq_num}, acc ->
            new_flags =
              Response.apply_flag_operation(msg, operation, flags, state.selected_folder)

            update_message_flags(msg, new_flags, state.mailbox)

            unless silent_store_operation?(operation) do
              flags_str = Response.format_flags(new_flags)
              Helpers.send_response(state.socket, "* #{seq_num} FETCH (FLAGS (#{flags_str}))")
            end

            Map.put(acc, msg.id, message_updates_from_flags(msg, new_flags))
          end)

        Helpers.send_response(state.socket, "#{tag} OK STORE completed")
        refreshed_state_messages = apply_message_updates(state.messages, updated_messages_by_id)

        {:continue,
         Map.merge(state, %{
           messages: refreshed_state_messages,
           recent_message_ids:
             RecentState.trim_recent_message_ids(
               refreshed_state_messages,
               Map.get(state, :recent_message_ids, MapSet.new())
             )
         })}

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid STORE arguments")
        {:continue, state}
    end
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

            unless silent_store_operation?(operation) do
              flags_str = Response.format_flags(new_flags)

              Helpers.send_response(
                state.socket,
                "* #{seq_num} FETCH (UID #{msg.id} FLAGS (#{flags_str}))"
              )
            end

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
          {:ok, fresh_messages} =
            Shared.load_folder_messages(state.mailbox, state.selected_folder)

          {:continue,
           Map.merge(state, %{
             messages: fresh_messages,
             recent_message_ids:
               RecentState.trim_recent_message_ids(
                 fresh_messages,
                 Map.get(state, :recent_message_ids, MapSet.new())
               )
           })}
        else
          refreshed_state_messages = apply_message_updates(state.messages, updated_messages_by_id)

          {:continue,
           Map.merge(state, %{
             messages: refreshed_state_messages,
             recent_message_ids:
               RecentState.trim_recent_message_ids(
                 refreshed_state_messages,
                 Map.get(state, :recent_message_ids, MapSet.new())
               )
           })}
        end

      {:error, _} ->
        Helpers.send_response(state.socket, "#{tag} BAD Invalid UID STORE arguments")
        {:continue, state}
    end
  end

  defp silent_store_operation?(operation) when is_binary(operation) do
    String.ends_with?(String.upcase(String.trim(operation)), ".SILENT")
  end

  def handle_expunge(tag, state) do
    {deleted_indices, remaining_messages} =
      expunge_deleted_messages(state.messages, state.mailbox)

    Enum.each(deleted_indices, fn seq_num ->
      Helpers.send_response(state.socket, "* #{seq_num} EXPUNGE")
    end)

    Helpers.send_response(state.socket, "#{tag} OK EXPUNGE completed")

    {:continue,
     Map.merge(state, %{
       messages: remaining_messages,
       recent_message_ids:
         RecentState.trim_recent_message_ids(
           remaining_messages,
           Map.get(state, :recent_message_ids, MapSet.new())
         )
     })}
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

    {:continue,
     Map.merge(state, %{
       messages: remaining_messages,
       recent_message_ids:
         RecentState.trim_recent_message_ids(
           remaining_messages,
           Map.get(state, :recent_message_ids, MapSet.new())
         )
     })}
  end

  def handle_check(tag, state) do
    {:ok, fresh_messages} = Shared.load_folder_messages(state.mailbox, state.selected_folder)
    recent_message_ids = RecentState.merge_recent_message_ids(state, fresh_messages)

    if length(fresh_messages) != length(state.messages) do
      Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")

      Helpers.send_response(
        state.socket,
        "* #{RecentState.count_recent_messages(fresh_messages, recent_message_ids)} RECENT"
      )
    end

    Helpers.send_response(state.socket, "#{tag} OK CHECK completed")
    {:continue, %{state | messages: fresh_messages, recent_message_ids: recent_message_ids}}
  end

  def handle_close(tag, state) do
    {_deleted_indices, _remaining_messages} =
      expunge_deleted_messages(state.messages, state.mailbox)

    Helpers.send_response(state.socket, "#{tag} OK CLOSE completed")

    {:continue,
     %{
       state
       | selected_folder: nil,
         messages: [],
         recent_message_ids: MapSet.new(),
         folder_key: nil,
         state: :authenticated
     }}
  end

  def handle_unselect(tag, state) do
    Helpers.send_response(state.socket, "#{tag} OK UNSELECT completed")

    {:continue,
     %{
       state
       | selected_folder: nil,
         messages: [],
         recent_message_ids: MapSet.new(),
         folder_key: nil,
         state: :authenticated
     }}
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
        current_status == "draft" -> "received"
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

                {:ok, new_msg.id}

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
    case dest_folder |> Helpers.canonical_system_folder_name() |> String.upcase() do
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
            Folders.find_custom_folder_by_name(mailbox_user_id, dest_folder)
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
end
