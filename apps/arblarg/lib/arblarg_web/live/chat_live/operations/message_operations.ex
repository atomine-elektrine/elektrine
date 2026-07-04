defmodule ArblargWeb.ChatLive.Operations.MessageOperations do
  @moduledoc "Handles all message-related operations: sending, editing, deleting, reactions, pagination.\nExtracted from ChatLive.Home.\n"
  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers
  alias ArblargWeb.ChatLive.Operations.Helpers
  alias Elektrine.Accounts.Storage
  alias Elektrine.Messaging, as: Messaging
  alias Elektrine.Messaging.SlashCommands
  alias Elektrine.Uploads
  @doc "Load older messages in the conversation (pagination upward).\n"
  def handle_event("load_older_messages", _, socket) do
    if socket.assigns.loading_older_messages || !socket.assigns.has_more_older_messages do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation.selected
      conversation_id = conversation.id
      user_id = socket.assigns.current_user.id
      socket = assign(socket, :loading_older_messages, true)

      data =
        Messaging.get_conversation_messages(
          conversation_id,
          user_id,
          limit: 50,
          before_id: socket.assigns.oldest_message_id
        )

      older_messages =
        Enum.reverse(data.messages)

      message_data = data
      new_messages = Helpers.dedupe_messages(older_messages ++ socket.assigns.messages)
      new_message_ids = Enum.map(older_messages, & &1.id)

      new_read_status =
        if new_message_ids != [] do
          Messaging.get_read_status_for_messages(new_message_ids, conversation_id)
        else
          %{}
        end

      {:noreply,
       socket
       |> assign(:messages, new_messages)
       |> assign(:message, %{
         socket.assigns.message
         | read_status: Map.merge(socket.assigns.message.read_status, new_read_status)
       })
       |> assign(:has_more_older_messages, message_data.has_more_older)
       |> assign(:oldest_message_id, message_data.oldest_id || socket.assigns.oldest_message_id)
       |> assign(:loading_older_messages, false)
       |> push_event("maintain_scroll_position", %{})}
    end
  end

  def handle_event("load_newer_messages", _, socket) do
    if socket.assigns.loading_newer_messages || !socket.assigns.has_more_newer_messages do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation.selected
      conversation_id = conversation.id
      user_id = socket.assigns.current_user.id
      socket = assign(socket, :loading_newer_messages, true)

      data =
        Messaging.get_conversation_messages(
          conversation_id,
          user_id,
          limit: 50,
          after_id: socket.assigns.newest_message_id
        )

      newer_messages =
        Enum.reverse(data.messages)

      message_data = data
      new_messages = Helpers.dedupe_messages(socket.assigns.messages ++ newer_messages)
      new_message_ids = Enum.map(newer_messages, & &1.id)

      new_read_status =
        if new_message_ids != [] do
          Messaging.get_read_status_for_messages(new_message_ids, conversation_id)
        else
          %{}
        end

      {:noreply,
       socket
       |> assign(:messages, new_messages)
       |> assign(:message, %{
         socket.assigns.message
         | read_status: Map.merge(socket.assigns.message.read_status, new_read_status)
       })
       |> assign(:has_more_newer_messages, message_data.has_more_newer)
       |> assign(:newest_message_id, message_data.newest_id || socket.assigns.newest_message_id)
       |> assign(:loading_newer_messages, false)}
    end
  end

  def handle_event("scroll_to_newest", _, socket) do
    {:noreply, push_event(socket, "scroll_to_bottom", %{})}
  end

  def handle_event("register_chat_encryption_device", params, socket) do
    case Messaging.register_chat_encryption_device(socket.assigns.current_user.id, params) do
      {:ok, _device} ->
        broadcast_chat_e2ee_devices_changed(socket)
        socket = refresh_chat_e2ee_devices(socket)
        {:reply, %{ok: true}, socket}

      {:error, _changeset} ->
        {:reply, %{ok: false, error: "invalid_device"}, socket}
    end
  end

  def handle_event("chat_e2ee_key", params, socket) do
    conversation_id = parse_int(Map.get(params, "conversation_id"))
    device_id = Map.get(params, "device_id")
    key_uid = Map.get(params, "key_uid")

    with %{id: selected_id} <- socket.assigns.conversation.selected,
         true <- conversation_id == selected_id,
         {:ok, wrapped_key} <-
           Messaging.get_wrapped_chat_key(
             conversation_id,
             socket.assigns.current_user.id,
             device_id,
             key_uid
           ) do
      {:reply, %{ok: true, wrapped_key: wrapped_key}, socket}
    else
      _ -> {:reply, %{ok: false, error: "key_not_found"}, socket}
    end
  end

  def handle_event("chat_typing", _params, socket) do
    {:noreply, broadcast_typing(socket)}
  end

  def handle_event("send_client_encrypted_message", params, socket) do
    case socket.assigns.conversation.selected do
      nil ->
        {:reply, %{ok: false, error: "no_conversation"}, socket}

      conversation ->
        reply_to_id = socket.assigns.message.reply_to && socket.assigns.message.reply_to.id

        attrs = %{
          "encrypted_payload" => Map.get(params, "encrypted_payload"),
          "key_packages" => Map.get(params, "key_packages", []),
          "search_index" => Map.get(params, "search_index", [])
        }

        case Messaging.create_client_encrypted_chat_text_message(
               conversation.id,
               socket.assigns.current_user.id,
               attrs,
               reply_to_id: reply_to_id
             ) do
          {:ok, message} ->
            socket = put_sent_message(socket, conversation, message)
            {:reply, %{ok: true}, socket}

          {:error, reason} ->
            {:reply, %{ok: false, error: to_string(reason)}, socket}
        end
    end
  end

  def handle_event("send_message", %{"message" => message_content}, socket) do
    trimmed_content = String.trim(message_content)

    upload_results =
      consume_uploaded_entries(socket, :chat_attachments, fn %{path: path}, entry ->
        user_id = socket.assigns.current_user.id

        upload_struct = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Uploads.upload_chat_attachment(upload_struct, user_id) do
          {:ok, metadata} ->
            {:ok,
             %{
               url: metadata.key,
               name: metadata.filename,
               type: metadata.content_type,
               size: metadata.size
             }}

          {:error, _reason} ->
            {:ok, %{upload_error: true, name: entry.client_name}}
        end
      end)

    {failed_uploads, uploaded_files} =
      Enum.split_with(upload_results, fn upload ->
        Map.get(upload, :upload_error, false)
      end)

    socket =
      if failed_uploads != [] do
        notify_error(
          socket,
          "One or more attachments failed to upload. Try a supported image format (JPG, PNG, WEBP, HEIC, AVIF) or a smaller file."
        )
      else
        socket
      end

    case maybe_apply_slash_command(trimmed_content, uploaded_files, socket) do
      {:halt, socket} ->
        {:noreply, socket}

      {:send, resolved_content, socket} ->
        has_content = resolved_content != "" || !Enum.empty?(uploaded_files)

        if has_content do
          case socket.assigns.conversation.selected do
            nil ->
              {:noreply, socket}

            conversation ->
              if Map.get(
                   socket.assigns.moderation.user_timeout_status,
                   socket.assigns.current_user.id,
                   false
                 ) do
                {:noreply,
                 notify_error(socket, "You are currently timed out and cannot send messages")}
              else
                reply_to_id =
                  if socket.assigns.message.reply_to do
                    socket.assigns.message.reply_to.id
                  else
                    nil
                  end

                socket =
                  assign(socket, :message, %{socket.assigns.message | loading_messages: true})

                result =
                  if Enum.empty?(uploaded_files) do
                    Messaging.create_text_message(
                      conversation.id,
                      socket.assigns.current_user.id,
                      resolved_content,
                      reply_to_id
                    )
                  else
                    media_urls = Enum.map(uploaded_files, & &1.url)

                    content =
                      if resolved_content != "" do
                        resolved_content
                      else
                        nil
                      end

                    media_metadata =
                      uploaded_files
                      |> Enum.map(fn file ->
                        {file.url,
                         %{size: file.size, filename: file.name, content_type: file.type}}
                      end)
                      |> Map.new()

                    Messaging.create_media_message(
                      conversation.id,
                      socket.assigns.current_user.id,
                      media_urls,
                      content,
                      media_metadata
                    )
                  end

                case result do
                  {:ok, message} ->
                    if !Enum.empty?(uploaded_files) do
                      Storage.update_user_storage(socket.assigns.current_user.id)
                    end

                    if socket.assigns[:typing_timer] do
                      Process.cancel_timer(socket.assigns.typing_timer)
                    end

                    Phoenix.PubSub.broadcast_from(
                      Elektrine.PubSub,
                      self(),
                      "conversation:#{conversation.id}",
                      {:user_stopped_typing, socket.assigns.current_user.id}
                    )

                    Elektrine.Messaging.Federation.publish_typing_stopped(
                      conversation.id,
                      socket.assigns.current_user.id
                    )

                    message_with_sender = Elektrine.Repo.preload(message, sender: [:profile])
                    conversations = socket.assigns.conversation.list

                    updated_conversations =
                      Enum.map(conversations, fn conv ->
                        if conv.id == conversation.id do
                          last_message_at = DateTime.from_naive!(message.inserted_at, "Etc/UTC")

                          %{
                            conv
                            | messages: [message_with_sender],
                              last_message_at: last_message_at
                          }
                        else
                          conv
                        end
                      end)

                    last_message_read_status =
                      Helpers.calculate_last_message_read_status(
                        updated_conversations,
                        socket.assigns.current_user.id
                      )

                    unread_counts =
                      Helpers.calculate_unread_counts(
                        updated_conversations,
                        socket.assigns.current_user.id
                      )

                    sorted_conversations =
                      Helpers.sort_conversations_by_unread(
                        updated_conversations,
                        unread_counts,
                        socket.assigns.current_user.id
                      )

                    scoped_conversations =
                      Helpers.scope_conversations_to_server(
                        sorted_conversations,
                        socket.assigns[:active_server_id]
                      )

                    filtered_conversations =
                      if socket.assigns.search.conversation_query != "" do
                        Helpers.filter_conversations(
                          scoped_conversations,
                          socket.assigns.search.conversation_query,
                          socket.assigns.current_user.id
                        )
                      else
                        scoped_conversations
                      end

                    updated_messages =
                      Helpers.dedupe_messages(socket.assigns.messages ++ [message])

                    updated_read_status =
                      Map.put(socket.assigns.message.read_status || %{}, message.id, [])

                    updated_socket =
                      socket
                      |> assign(:messages, updated_messages)
                      |> assign(:newest_message_id, message.id)
                      |> assign(:has_more_newer_messages, false)
                      |> assign(:message, %{
                        socket.assigns.message
                        | new_message: "",
                          reply_to: nil,
                          loading_messages: false,
                          read_status: updated_read_status
                      })
                      |> assign(:typing_timer, nil)
                      |> assign(:conversation, %{
                        socket.assigns.conversation
                        | list: sorted_conversations,
                          filtered: filtered_conversations,
                          last_message_read_status: last_message_read_status
                      })

                    updated_socket =
                      if message.media_urls && message.media_urls != [] do
                        Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 50)
                        Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 200)
                        Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 500)
                        Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 1000)
                        Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 1500)
                        updated_socket
                      else
                        push_event(updated_socket, "scroll_to_bottom", %{})
                      end

                    {:noreply, updated_socket}

                  {:error, :rate_limited} ->
                    {:noreply,
                     socket
                     |> assign(:message, %{socket.assigns.message | loading_messages: false})
                     |> notify_error("Sending too fast! Please slow down.")}

                  {:error, reason} ->
                    error_message = Elektrine.Privacy.privacy_error_message(reason)

                    {:noreply,
                     socket
                     |> assign(:message, %{socket.assigns.message | loading_messages: false})
                     |> notify_error(error_message)}
                end
              end
          end
        else
          {:noreply, socket}
        end
    end
  end

  def handle_event("update_message", %{"message" => message_content}, socket) do
    socket =
      if Elektrine.Strings.present?(message_content), do: broadcast_typing(socket), else: socket

    {:noreply, assign(socket, :message, %{socket.assigns.message | new_message: message_content})}
  end

  def handle_event("handle_keydown", %{"key" => "Enter"}, socket) do
    trimmed_content = String.trim(socket.assigns.message.new_message)

    if trimmed_content != "" do
      handle_event("send_message", %{"message" => trimmed_content}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("stop_typing", _params, socket) do
    case socket.assigns.conversation.selected do
      nil ->
        {:noreply, socket}

      conversation ->
        if socket.assigns[:typing_timer] do
          Process.cancel_timer(socket.assigns.typing_timer)
        end

        Phoenix.PubSub.broadcast_from(
          Elektrine.PubSub,
          self(),
          "conversation:#{conversation.id}",
          {:user_stopped_typing, socket.assigns.current_user.id}
        )

        Elektrine.Messaging.Federation.publish_typing_stopped(
          conversation.id,
          socket.assigns.current_user.id
        )

        {:noreply, assign(socket, :typing_timer, nil)}
    end
  end

  def handle_event(
        "react_to_message",
        %{"message_id" => message_id_str, "emoji" => emoji},
        socket
      ) do
    with {:ok, message_id} <- parse_positive_int(message_id_str),
         false <-
           Map.get(
             socket.assigns.moderation.user_timeout_status,
             socket.assigns.current_user.id,
             false
           ) do
      case Messaging.add_chat_reaction(message_id, socket.assigns.current_user.id, emoji) do
        {:ok, _reaction} -> {:noreply, socket}
        {:error, _} -> {:noreply, socket}
      end
    else
      true ->
        {:noreply,
         notify_error(socket, "You are currently timed out and cannot react to messages")}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_message", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case Messaging.delete_chat_message(message_id, socket.assigns.current_user.id) do
            {:ok, _deleted_message} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_info("Message deleted")}

            {:error, :unauthorized} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_error("You can only delete your own messages")}

            {:error, :not_found} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_error("Message not found")}

            {:error, _} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_error("Failed to delete message")}
          end

        :error ->
          {:noreply,
           socket
           |> hide_message_context_menu()
           |> notify_error("Failed to delete message")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("delete_message_admin", %{"message_id" => message_id}, socket) do
    if Helpers.conversation_admin_socket?(socket) do
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          case Messaging.delete_chat_message(message_id, socket.assigns.current_user.id, true) do
            {:ok, deleted_message} ->
              conversation_id =
                socket.assigns.conversation.selected && socket.assigns.conversation.selected.id

              Messaging.log_moderation_action(
                "delete_message",
                deleted_message.sender_id,
                socket.assigns.current_user.id,
                conversation_id: conversation_id,
                reason: "Admin message deletion",
                details: %{message_id: message_id, message_content: deleted_message.content}
              )

              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_info("Message deleted")}

            {:error, :not_found} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_info("Message not found")}

            {:error, :already_deleted} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_info("Message already deleted")}

            {:error, _} ->
              {:noreply,
               socket
               |> hide_message_context_menu()
               |> notify_error("Failed to delete message")}
          end

        :error ->
          {:noreply,
           socket
           |> hide_message_context_menu()
           |> notify_error("Failed to delete message")}
      end
    else
      {:noreply,
       socket
       |> hide_message_context_menu()
       |> notify_error("Unauthorized")}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref, "upload_name" => upload_name}, socket) do
    upload_atom =
      case upload_name do
        "chat_attachments" -> :chat_attachments
        "server_icon_upload" -> :server_icon_upload
        "group_avatar_upload" -> :group_avatar_upload
        "channel_avatar_upload" -> :channel_avatar_upload
        _ -> :chat_attachments
      end

    {:noreply, cancel_upload(socket, upload_atom, ref)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :chat_attachments, ref)}
  end

  def handle_event("scroll_to_message", %{"message_id" => message_id}, socket) do
    {:noreply, socket |> push_event("scroll_to_message", %{message_id: message_id})}
  end

  def handle_event("search_messages", params, socket) do
    query = Map.get(params, "query") || Map.get(params, "value") || ""
    search_tokens = Map.get(params, "search_tokens", [])

    if String.length(query) >= 2 and socket.assigns.conversation.selected do
      case Messaging.search_messages_in_conversation(
             socket.assigns.conversation.selected.id,
             socket.assigns.current_user.id,
             query,
             search_tokens: search_tokens
           ) do
        {:ok, results} ->
          {:noreply,
           assign(socket, :search, %{
             socket.assigns.search
             | message_query: query,
               message_results: results
           })}

        {:error, _} ->
          {:noreply,
           assign(socket, :search, %{
             socket.assigns.search
             | message_query: query,
               message_results: []
           })}
      end
    else
      {:noreply,
       assign(socket, :search, %{
         socket.assigns.search
         | message_query: query,
           message_results: []
       })}
    end
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :message, %{socket.assigns.message | reply_to: nil})}
  end

  def handle_event("reply_to_message", %{"message_id" => message_id}, socket) do
    message =
      case parse_positive_int(message_id) do
        {:ok, message_id} -> Enum.find(socket.assigns.messages, &(&1.id == message_id))
        :error -> nil
      end

    {:noreply,
     socket
     |> hide_message_context_menu()
     |> assign(:message, %{socket.assigns.message | reply_to: message})}
  end

  def handle_event("copy_message", %{"message_id" => message_id}, socket) do
    message =
      case parse_positive_int(message_id) do
        {:ok, message_id} -> Enum.find(socket.assigns.messages, &(&1.id == message_id))
        :error -> nil
      end

    socket = hide_message_context_menu(socket)

    if message do
      {:noreply,
       push_event(socket, "copy_to_clipboard", %{text: message.content, type: "message"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pin_message", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        case Messaging.pin_chat_message(message_id, socket.assigns.current_user.id) do
          {:ok, _message} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_info("Message pinned")}

          {:error, :unauthorized} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_error("Only moderators can pin messages")}

          {:error, :pin_limit_reached} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_error("Pin limit reached for this conversation")}

          {:error, :already_pinned} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_info("Message is already pinned")}

          {:error, _} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_error("Failed to pin message")}
        end

      :error ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> notify_error("Failed to pin message")}
    end
  end

  def handle_event("unpin_message", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        case Messaging.unpin_chat_message(message_id, socket.assigns.current_user.id) do
          {:ok, _message} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_info("Message unpinned")}

          {:error, :unauthorized} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_error("Only moderators can unpin messages")}

          {:error, _} ->
            {:noreply,
             socket
             |> hide_message_context_menu()
             |> notify_error("Failed to unpin message")}
        end

      :error ->
        {:noreply,
         socket
         |> hide_message_context_menu()
         |> notify_error("Failed to unpin message")}
    end
  end

  def handle_event(
        "send_voice_message",
        %{"audio_data" => audio_data, "duration" => duration, "mime_type" => mime_type},
        socket
      ) do
    case socket.assigns.conversation.selected do
      nil ->
        {:noreply, socket}

      conversation ->
        if Map.get(
             socket.assigns.moderation.user_timeout_status,
             socket.assigns.current_user.id,
             false
           ) do
          {:noreply, notify_error(socket, "You are currently timed out and cannot send messages")}
        else
          case Base.decode64(audio_data) do
            {:ok, audio_binary} ->
              extension =
                case mime_type do
                  "audio/webm" -> "webm"
                  "audio/mp4" -> "m4a"
                  "audio/ogg" -> "ogg"
                  _ -> "webm"
                end

              filename = "voice_#{System.system_time(:second)}.#{extension}"

              case Uploads.upload_voice_message(
                     audio_binary,
                     filename,
                     mime_type,
                     socket.assigns.current_user.id
                   ) do
                {:ok, metadata} ->
                  case Messaging.create_voice_message(
                         conversation.id,
                         socket.assigns.current_user.id,
                         metadata.key,
                         duration,
                         mime_type
                       ) do
                    {:ok, _message} ->
                      {:noreply, socket}

                    {:error, :rate_limited} ->
                      {:noreply, notify_error(socket, "Sending too fast! Please slow down.")}

                    {:error, _reason} ->
                      {:noreply, notify_error(socket, "Failed to send voice message")}
                  end

                {:error, _reason} ->
                  {:noreply, notify_error(socket, "Failed to upload voice message")}
              end

            :error ->
              {:noreply, notify_error(socket, "Invalid audio data")}
          end
        end
    end
  end

  def handle_event("voice_recording_error", %{"error" => error}, socket) do
    {:noreply, notify_error(socket, error)}
  end

  defp refresh_chat_e2ee_devices(socket) do
    case socket.assigns.conversation.selected do
      %{id: conversation_id} ->
        assign(
          socket,
          :chat_e2ee_devices,
          Messaging.list_chat_encryption_devices_for_conversation(conversation_id)
        )

      _ ->
        socket
    end
  end

  defp broadcast_chat_e2ee_devices_changed(socket) do
    case socket.assigns.conversation.selected do
      %{id: conversation_id} ->
        Phoenix.PubSub.broadcast_from(
          Elektrine.PubSub,
          self(),
          "conversation:#{conversation_id}",
          {:chat_e2ee_devices_changed, conversation_id}
        )

      _ ->
        :ok
    end
  end

  defp put_sent_message(socket, conversation, message) do
    message = Elektrine.Repo.preload(message, sender: [:profile])
    unread_counts = Map.put(socket.assigns.conversation.unread_counts || %{}, conversation.id, 0)

    if socket.assigns[:typing_timer] do
      Process.cancel_timer(socket.assigns.typing_timer)
    end

    Phoenix.PubSub.broadcast_from(
      Elektrine.PubSub,
      self(),
      "conversation:#{conversation.id}",
      {:user_stopped_typing, socket.assigns.current_user.id}
    )

    Elektrine.Messaging.Federation.publish_typing_stopped(
      conversation.id,
      socket.assigns.current_user.id
    )

    conversations =
      update_sent_conversation_preview(socket.assigns.conversation.list, conversation, message)

    last_message_read_status =
      Helpers.calculate_last_message_read_status(conversations, socket.assigns.current_user.id)

    sorted_conversations =
      Helpers.sort_conversations_by_unread(
        conversations,
        unread_counts,
        socket.assigns.current_user.id
      )

    scoped_conversations =
      Helpers.scope_conversations_to_server(
        sorted_conversations,
        socket.assigns[:active_server_id]
      )

    filtered_conversations =
      if socket.assigns.search.conversation_query != "" do
        Helpers.filter_conversations(
          scoped_conversations,
          socket.assigns.search.conversation_query,
          socket.assigns.current_user.id
        )
      else
        scoped_conversations
      end

    socket
    |> assign(:messages, Helpers.dedupe_messages(socket.assigns.messages ++ [message]))
    |> assign(:newest_message_id, message.id)
    |> assign(:has_more_newer_messages, false)
    |> assign(:message, %{
      socket.assigns.message
      | new_message: "",
        reply_to: nil,
        loading_messages: false,
        read_status: Map.put(socket.assigns.message.read_status || %{}, message.id, [])
    })
    |> assign(:typing_timer, nil)
    |> assign(:conversation, %{
      socket.assigns.conversation
      | list: sorted_conversations,
        filtered: filtered_conversations,
        unread_counts: unread_counts,
        last_message_read_status: last_message_read_status
    })
    |> push_event("clear_message_input", %{})
    |> push_event("scroll_to_bottom", %{})
  end

  defp update_sent_conversation_preview(conversations, conversation, message)
       when is_list(conversations) do
    Enum.map(conversations, fn current ->
      if current.id == conversation.id do
        %{
          current
          | messages: [message],
            last_message_at: message_datetime(message, current.last_message_at)
        }
      else
        current
      end
    end)
  end

  defp update_sent_conversation_preview(_, _conversation, _message), do: []

  defp message_datetime(%{inserted_at: %DateTime{} = datetime}, _fallback), do: datetime

  defp message_datetime(%{inserted_at: %NaiveDateTime{} = naive_datetime}, _fallback),
    do: DateTime.from_naive!(naive_datetime, "Etc/UTC")

  defp message_datetime(_message, fallback), do: fallback

  defp broadcast_typing(socket) do
    case socket.assigns.conversation.selected do
      nil ->
        socket

      conversation ->
        should_broadcast =
          case socket.assigns[:last_typing_broadcast] do
            nil -> true
            last_time -> System.system_time(:millisecond) - last_time > 2000
          end

        socket =
          if should_broadcast do
            Phoenix.PubSub.broadcast_from(
              Elektrine.PubSub,
              self(),
              "conversation:#{conversation.id}",
              {:user_typing, socket.assigns.current_user.id,
               socket.assigns.current_user.handle || socket.assigns.current_user.username}
            )

            Elektrine.Messaging.Federation.publish_typing_started(
              conversation.id,
              socket.assigns.current_user.id
            )

            assign(socket, :last_typing_broadcast, System.system_time(:millisecond))
          else
            socket
          end

        if socket.assigns[:typing_timer] do
          Process.cancel_timer(socket.assigns.typing_timer)
        end

        timer = Process.send_after(self(), :clear_typing, 3000)
        assign(socket, :typing_timer, timer)
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_positive_int(value) do
    case parse_int(value) do
      integer when is_integer(integer) and integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp hide_message_context_menu(socket) do
    assign(socket, :context_menu, %{
      socket.assigns.context_menu
      | message: nil,
        selected_text: nil
    })
  end

  defp maybe_apply_slash_command("", _uploaded_files, socket) do
    {:send, "", socket}
  end

  defp maybe_apply_slash_command(content, uploaded_files, socket) do
    if uploaded_files != [] or not String.starts_with?(content, "/") do
      {:send, content, socket}
    else
      conversation = socket.assigns.conversation.selected
      user = socket.assigns.current_user

      case SlashCommands.process(content,
             conversation: conversation,
             endpoint_url: ElektrineWeb.Endpoint.url(),
             user_display: user.display_name,
             user_handle: user.handle,
             username: user.username
           ) do
        {:send, resolved_content} -> {:send, resolved_content, socket}
        {:noop, info_message} -> {:halt, notify_info(socket, info_message)}
        {:error, error_message} -> {:halt, notify_error(socket, error_message)}
      end
    end
  end
end
