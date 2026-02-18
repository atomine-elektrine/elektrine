defmodule ElektrineWeb.ChatLive.Operations.MessageOperations do
  @moduledoc """
  Handles all message-related operations: sending, editing, deleting, reactions, pagination.
  Extracted from ChatLive.Home.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Messaging, as: Messaging
  alias Elektrine.Messaging.SlashCommands
  alias Elektrine.Accounts.Storage
  alias Elektrine.Uploads
  alias ElektrineWeb.ChatLive.Operations.Helpers

  @doc """
  Load older messages in the conversation (pagination upward).
  """
  def handle_event("load_older_messages", _, socket) do
    if socket.assigns.loading_older_messages || !socket.assigns.has_more_older_messages do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation.selected
      conversation_id = conversation.id
      user_id = socket.assigns.current_user.id

      socket = assign(socket, :loading_older_messages, true)

      # Load older messages from messages table
      data =
        Messaging.get_conversation_messages(
          conversation_id,
          user_id,
          limit: 50,
          before_id: socket.assigns.oldest_message_id
        )

      older_messages =
        data.messages
        |> Enum.reverse()
        |> Elektrine.Messaging.Message.decrypt_messages()

      message_data = data

      new_messages = older_messages ++ socket.assigns.messages

      # Load read status for new messages
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

      # Load newer messages from messages table
      data =
        Messaging.get_conversation_messages(
          conversation_id,
          user_id,
          limit: 50,
          after_id: socket.assigns.newest_message_id
        )

      newer_messages =
        data.messages
        |> Enum.reverse()
        |> Elektrine.Messaging.Message.decrypt_messages()

      message_data = data

      new_messages = socket.assigns.messages ++ newer_messages

      # Load read status for new messages
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

  def handle_event("send_message", %{"message" => message_content}, socket) do
    trimmed_content = String.trim(message_content)

    # Process any uploaded files
    uploaded_files =
      consume_uploaded_entries(socket, :chat_attachments, fn %{path: path}, entry ->
        user_id = socket.assigns.current_user.id

        # Create a Plug.Upload struct to use with Uploads module
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
            {:postpone, :error}
        end
      end)

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
              # Check if user is timed out
              if Map.get(
                   socket.assigns.moderation.user_timeout_status,
                   socket.assigns.current_user.id,
                   false
                 ) do
                {:noreply,
                 notify_error(socket, "You are currently timed out and cannot send messages")}
              else
                reply_to_id =
                  if socket.assigns.message.reply_to,
                    do: socket.assigns.message.reply_to.id,
                    else: nil

                socket =
                  assign(socket, :message, %{socket.assigns.message | loading_messages: true})

                # Create message based on whether we have uploads or just text
                result =
                  if !Enum.empty?(uploaded_files) do
                    media_urls = Enum.map(uploaded_files, & &1.url)
                    content = if resolved_content != "", do: resolved_content, else: nil

                    # Build metadata map with file sizes indexed by URL
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
                  else
                    Messaging.create_text_message(
                      conversation.id,
                      socket.assigns.current_user.id,
                      resolved_content,
                      reply_to_id
                    )
                  end

                case result do
                  {:ok, message} ->
                    # Update storage after sending message (especially if attachments)
                    # Do synchronously for immediate UI feedback
                    if !Enum.empty?(uploaded_files) do
                      Storage.update_user_storage(socket.assigns.current_user.id)
                    end

                    # Clear typing indicator when message is sent
                    if socket.assigns[:typing_timer] do
                      Process.cancel_timer(socket.assigns.typing_timer)
                    end

                    Phoenix.PubSub.broadcast_from(
                      Elektrine.PubSub,
                      self(),
                      "conversation:#{conversation.id}",
                      {:user_stopped_typing, socket.assigns.current_user.id}
                    )

                    # Immediately update conversation list to show new message as unread
                    # Reload the message with sender preloaded to match conversation list format
                    message_with_sender = Elektrine.Repo.preload(message, sender: [:profile])

                    conversations = socket.assigns.conversation.list

                    updated_conversations =
                      Enum.map(conversations, fn conv ->
                        if conv.id == conversation.id do
                          # Update this conversation's last message
                          # Convert NaiveDateTime to DateTime for consistency
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

                    # Recalculate read status for conversation list (will show single checkmark)
                    last_message_read_status =
                      Helpers.calculate_last_message_read_status(
                        updated_conversations,
                        socket.assigns.current_user.id
                      )

                    # Re-sort and re-filter conversations
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

                    filtered_conversations =
                      if socket.assigns.search.conversation_query != "" do
                        Helpers.filter_conversations(
                          sorted_conversations,
                          socket.assigns.search.conversation_query,
                          socket.assigns.current_user.id
                        )
                      else
                        sorted_conversations
                      end

                    updated_messages =
                      if Enum.any?(socket.assigns.messages, &(&1.id == message.id)) do
                        socket.assigns.messages
                      else
                        socket.assigns.messages ++ [message]
                      end

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
    # Handle typing indicator when user is actively typing
    socket =
      if String.trim(message_content) != "" && socket.assigns.conversation.selected do
        # Only broadcast typing if we haven't recently
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
              "conversation:#{socket.assigns.conversation.selected.id}",
              {:user_typing, socket.assigns.current_user.id,
               socket.assigns.current_user.handle || socket.assigns.current_user.username}
            )

            assign(socket, :last_typing_broadcast, System.system_time(:millisecond))
          else
            socket
          end

        # Cancel previous typing timeout timer if exists
        if socket.assigns[:typing_timer] do
          Process.cancel_timer(socket.assigns.typing_timer)
        end

        # Set new timer to clear typing after 3 seconds
        timer = Process.send_after(self(), :clear_typing, 3000)
        assign(socket, :typing_timer, timer)
      else
        socket
      end

    {:noreply, assign(socket, :message, %{socket.assigns.message | new_message: message_content})}
  end

  def handle_event("handle_keydown", %{"key" => "Enter"}, socket) do
    # Send message on Enter without restrictions
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
        # Cancel typing timer if exists
        if socket.assigns[:typing_timer] do
          Process.cancel_timer(socket.assigns.typing_timer)
        end

        # Broadcast stop typing to other users
        Phoenix.PubSub.broadcast_from(
          Elektrine.PubSub,
          self(),
          "conversation:#{conversation.id}",
          {:user_stopped_typing, socket.assigns.current_user.id}
        )

        {:noreply, assign(socket, :typing_timer, nil)}
    end
  end

  def handle_event(
        "react_to_message",
        %{"message_id" => message_id_str, "emoji" => emoji},
        socket
      ) do
    message_id = String.to_integer(message_id_str)

    # Check if user is timed out
    if Map.get(
         socket.assigns.moderation.user_timeout_status,
         socket.assigns.current_user.id,
         false
       ) do
      {:noreply, notify_error(socket, "You are currently timed out and cannot react to messages")}
    else
      case Messaging.add_reaction(message_id, socket.assigns.current_user.id, emoji) do
        {:ok, _reaction} -> {:noreply, socket}
        {:error, _} -> {:noreply, socket}
      end
    end
  end

  def handle_event("delete_message", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _deleted_message} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_info("Message deleted")}

        {:error, :unauthorized} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_error("You can only delete your own messages")}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_error("Message not found")}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_error("Failed to delete message")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("delete_message_admin", %{"message_id" => message_id}, socket) do
    if Helpers.conversation_admin_socket?(socket) do
      message_id = String.to_integer(message_id)

      case Messaging.admin_delete_message(message_id, socket.assigns.current_user) do
        {:ok, deleted_message} ->
          # Log the moderation action (use message sender as target_user_id)
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
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_info("Message deleted")}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_info("Message not found")}

        {:error, :already_deleted} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_info("Message already deleted")}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
           |> notify_error("Failed to delete message")}
      end
    else
      {:noreply,
       socket
       |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
       |> notify_error("Unauthorized")}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    # Just validate - don't consume yet
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :chat_attachments, ref)}
  end

  def handle_event("scroll_to_message", %{"message_id" => message_id}, socket) do
    {:noreply,
     socket
     |> push_event("scroll_to_message", %{message_id: message_id})}
  end

  def handle_event("search_messages", %{"value" => query}, socket) do
    if String.length(query) >= 2 and socket.assigns.conversation.selected do
      case Messaging.search_messages_in_conversation(
             socket.assigns.conversation.selected.id,
             socket.assigns.current_user.id,
             query
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
    message = Enum.find(socket.assigns.messages, &(&1.id == String.to_integer(message_id)))

    {:noreply,
     socket
     |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
     |> assign(:message, %{socket.assigns.message | reply_to: message})}
  end

  def handle_event("copy_message", %{"message_id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == String.to_integer(message_id)))

    {:noreply,
     socket
     |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
     |> push_event("copy_to_clipboard", %{text: message.content, type: "message"})}
  end

  def handle_event("pin_message", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)

    case Messaging.pin_message(message_id, socket.assigns.current_user.id) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
         |> notify_info("Message pinned")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
         |> notify_error("Only moderators can pin messages")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
         |> notify_error("Failed to pin message")}
    end
  end

  def handle_event("unpin_message", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)

    case Messaging.unpin_message(message_id, socket.assigns.current_user.id) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
         |> notify_info("Message unpinned")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
         |> notify_error("Only moderators can unpin messages")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:context_menu, %{socket.assigns.context_menu | message: nil})
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
        # Check if user is timed out
        if Map.get(
             socket.assigns.moderation.user_timeout_status,
             socket.assigns.current_user.id,
             false
           ) do
          {:noreply, notify_error(socket, "You are currently timed out and cannot send messages")}
        else
          # Decode base64 audio data
          case Base.decode64(audio_data) do
            {:ok, audio_binary} ->
              # Determine file extension from mime type
              extension =
                case mime_type do
                  "audio/webm" -> "webm"
                  "audio/mp4" -> "m4a"
                  "audio/ogg" -> "ogg"
                  _ -> "webm"
                end

              filename = "voice_#{System.system_time(:second)}.#{extension}"

              # Upload to storage
              case Uploads.upload_voice_message(
                     audio_binary,
                     filename,
                     mime_type,
                     socket.assigns.current_user.id
                   ) do
                {:ok, metadata} ->
                  # Create voice message
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

  defp maybe_apply_slash_command("", _uploaded_files, socket), do: {:send, "", socket}

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
        {:send, resolved_content} ->
          {:send, resolved_content, socket}

        {:noop, info_message} ->
          {:halt, notify_info(socket, info_message)}

        {:error, error_message} ->
          {:halt, notify_error(socket, error_message)}
      end
    end
  end
end
