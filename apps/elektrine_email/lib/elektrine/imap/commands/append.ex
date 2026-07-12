defmodule Elektrine.IMAP.Commands.Append do
  @moduledoc "IMAP APPEND command, including literal data reception and message storage."

  require Logger

  alias Elektrine.Constants
  alias Elektrine.IMAP.{AppendParser, Folders, Helpers, RecentState}
  alias Elektrine.IMAP.Commands.Shared
  alias Elektrine.Mail.Socket

  defp max_message_size, do: Constants.imap_max_message_size()

  def handle_append(tag, args, state) do
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
                  Elektrine.Async.start(fn ->
                    Elektrine.Jobs.AttachmentUploader.upload_message_attachments(message.id)
                  end)
                end

                state =
                  if String.upcase(folder) == String.upcase(state.selected_folder || "") do
                    {:ok, fresh_messages} =
                      Shared.load_folder_messages(state.mailbox, state.selected_folder)

                    recent_message_ids =
                      RecentState.merge_recent_message_ids(state, fresh_messages)

                    Helpers.send_response(state.socket, "* #{length(fresh_messages)} EXISTS")

                    Helpers.send_response(
                      state.socket,
                      "* #{RecentState.count_recent_messages(fresh_messages, recent_message_ids)} RECENT"
                    )

                    Map.merge(state, %{
                      messages: fresh_messages,
                      recent_message_ids: recent_message_ids
                    })
                  else
                    state
                  end

                Helpers.send_response(
                  state.socket,
                  "#{tag} OK [APPENDUID #{state.uid_validity} #{message.id}] APPEND completed"
                )

                {:continue, state}

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

                {:continue, state}
            end

          {:error, :message_too_large} ->
            Helpers.send_response(state.socket, "#{tag} NO [TOOBIG] Message exceeds size limit")
            {:continue, state}

          {:error, reason} ->
            Logger.error("APPEND receive data failed: #{inspect(reason)}")
            Helpers.send_response(state.socket, "#{tag} NO APPEND failed")
            {:continue, state}
        end

      {:error, reason} ->
        Logger.error("APPEND parse failed: #{inspect(reason)}")
        Helpers.send_response(state.socket, "#{tag} BAD Invalid APPEND arguments")
        {:continue, state}
    end
  end

  defp receive_literal_data(socket, size) do
    if size > max_message_size() do
      {:error, :message_too_large}
    else
      Socket.setopts(socket, packet: :raw, active: false)

      result =
        try do
          receive_literal_chunks(socket, size, <<>>, 0)
        rescue
          e ->
            Logger.error("IMAP APPEND: Exception during receive: #{inspect(e)}")
            {:error, :receive_exception}
        after
          Socket.setopts(socket, packet: :line, active: false)
        end

      result
    end
  end

  defp receive_literal_chunks(socket, total_size, acc, received_so_far) do
    remaining = total_size - received_so_far

    if remaining <= 0 do
      case Socket.recv(socket, 2, 5000) do
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

      case Socket.recv(socket, chunk_size, 60_000) do
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
    {headers, body, message} =
      try do
        AppendParser.parse_email_data(data)
      rescue
        e ->
          Logger.error("IMAP APPEND: Email parsing failed: #{inspect(e)}")
          {%{"subject" => "(Parse Error)", "from" => "", "to" => ""}, "", nil}
      end

    raw_subject = Map.get(headers, "subject", "(No Subject)")
    subject = Elektrine.Email.Receiver.decode_mail_header(raw_subject)

    if subject == "(Parse Error)" do
      {:error, :parse_error}
    else
      folder_clean = Helpers.canonical_system_folder_name(folder)
      folder_lower = String.downcase(folder_clean)

      custom_folder_id =
        cond do
          folder_lower in ["inbox", "sent", "drafts", "trash", "spam"] ->
            nil

          is_integer(mailbox.user_id) ->
            case Folders.find_custom_folder_by_name(mailbox.user_id, folder_clean) do
              nil -> nil
              custom_folder -> custom_folder.id
            end

          true ->
            nil
        end

      text_body =
        AppendParser.extract_text_body(body, headers, message)

      html_body =
        AppendParser.extract_html_body(body, headers, message)

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
          in_reply_to: Map.get(headers, "in-reply-to"),
          references: Map.get(headers, "references"),
          text_body: text_body,
          raw_source: data,
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
          if html = html_body do
            Map.put(message_attrs, :html_body, html)
          else
            message_attrs
          end

        existing = Elektrine.Email.get_message_by_id(message_attrs.message_id, mailbox.id)

        if existing do
          {:ok, existing}
        else
          message_attrs =
            case AppendParser.extract_attachments(body, headers, message) do
              attachments when map_size(attachments) > 0 ->
                validated_attachments = AppendParser.validate_extracted_attachments(attachments)

                updated_html =
                  AppendParser.replace_cid_with_data_urls(
                    message_attrs[:html_body],
                    validated_attachments
                  )

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
end
