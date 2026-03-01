defmodule ElektrineWeb.ChatLive.Operations.MessageInfoOperations do
  @moduledoc false

  @doc false
  def route_info(info, socket) do
    case info do
      {:message_edited, message} ->
        {:handled, handle_message_edited(socket, message)}

      {:message_deleted, message} ->
        {:handled, handle_message_deleted(socket, message)}

      {:chat_message_updated, message} ->
        {:handled, handle_chat_message_updated(socket, message)}

      {:chat_message_deleted, message_id} ->
        {:handled, handle_chat_message_deleted(socket, message_id)}

      {:chat_reaction_added, message_id, reaction} ->
        {:handled, handle_chat_reaction_added(socket, message_id, reaction)}

      {:chat_reaction_removed, message_id, user_id, emoji} ->
        {:handled, handle_chat_reaction_removed(socket, message_id, user_id, emoji)}

      {:chat_reaction_removed, message_id, _user_id, emoji, remote_actor_id} ->
        {:handled, handle_chat_reaction_removed(socket, message_id, nil, emoji, remote_actor_id)}

      {:chat_remote_read_receipt, receipt} when is_map(receipt) ->
        {:handled, handle_chat_remote_read_receipt(socket, receipt)}

      {:federation_presence_update, payload} when is_map(payload) ->
        {:handled, handle_federation_presence_update(socket, payload)}

      {:message_pinned, message} ->
        {:handled, handle_message_pinned(socket, message)}

      {:message_unpinned, message} ->
        {:handled, handle_message_unpinned(socket, message)}

      {:reaction_added, reaction} ->
        {:handled, handle_reaction_added(socket, reaction)}

      {:reaction_removed, reaction} ->
        {:handled, handle_reaction_removed(socket, reaction)}

      {:message_link_preview_updated, updated_message} ->
        {:handled, handle_message_link_preview_updated(socket, updated_message)}

      {:notification_count_updated, new_count} ->
        {:handled, handle_notification_count_updated(socket, new_count)}

      _ ->
        :unhandled
    end
  end

  def handle_message_edited(socket, message) do
    if selected_conversation_matches?(socket, message.conversation_id) do
      decrypted_message = Elektrine.Messaging.Message.decrypt_content(message)

      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id, do: decrypted_message, else: msg
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_message_deleted(socket, message) do
    if selected_conversation_matches?(socket, message.conversation_id) do
      messages = Enum.reject(socket.assigns.messages, fn msg -> msg.id == message.id end)
      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_chat_message_updated(socket, message) do
    if selected_conversation_matches?(socket, message.conversation_id) do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id, do: message, else: msg
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_chat_message_deleted(socket, message_id) do
    messages = Enum.reject(socket.assigns.messages, fn msg -> msg.id == message_id end)
    {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
  end

  def handle_chat_reaction_added(socket, message_id, reaction) do
    messages =
      Enum.map(socket.assigns.messages, fn message ->
        if message.id == message_id do
          existing_reactions = Map.get(message, :reactions, []) || []

          already_exists =
            Enum.any?(existing_reactions, fn existing ->
              existing.emoji == reaction.emoji and
                existing.user_id == reaction.user_id and
                existing.remote_actor_id == reaction.remote_actor_id
            end)

          updated_reactions =
            if already_exists, do: existing_reactions, else: existing_reactions ++ [reaction]

          %{message | reactions: updated_reactions}
        else
          message
        end
      end)

    {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
  end

  def handle_chat_reaction_removed(socket, message_id, user_id, emoji) do
    messages =
      Enum.map(socket.assigns.messages, fn message ->
        if message.id == message_id do
          reactions =
            (Map.get(message, :reactions, []) || [])
            |> Enum.reject(fn reaction ->
              reaction.emoji == emoji and reaction.user_id == user_id
            end)

          %{message | reactions: reactions}
        else
          message
        end
      end)

    {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
  end

  def handle_chat_reaction_removed(socket, message_id, _user_id, emoji, remote_actor_id) do
    messages =
      Enum.map(socket.assigns.messages, fn message ->
        if message.id == message_id do
          reactions =
            (Map.get(message, :reactions, []) || [])
            |> Enum.reject(fn reaction ->
              reaction.emoji == emoji and reaction.remote_actor_id == remote_actor_id
            end)

          %{message | reactions: reactions}
        else
          message
        end
      end)

    {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
  end

  def handle_chat_remote_read_receipt(socket, receipt) when is_map(receipt) do
    message_id = receipt[:message_id] || receipt["message_id"]

    if is_integer(message_id) and Enum.any?(socket.assigns.messages, &(&1.id == message_id)) do
      current_read_status = socket.assigns.message.read_status || %{}
      current_readers = Map.get(current_read_status, message_id, [])

      remote_reader = %{
        user_id: nil,
        remote_actor_id: receipt[:remote_actor_id] || receipt["remote_actor_id"],
        username: receipt[:username] || receipt["username"] || "@remote",
        avatar: receipt[:avatar] || receipt["avatar"]
      }

      updated_readers =
        current_readers
        |> Enum.reject(fn reader ->
          is_integer(reader[:remote_actor_id]) and
            reader[:remote_actor_id] == remote_reader.remote_actor_id
        end)
        |> Kernel.++([remote_reader])

      updated_read_status = Map.put(current_read_status, message_id, updated_readers)

      {:noreply,
       Phoenix.Component.assign(socket, :message, %{
         socket.assigns.message
         | read_status: updated_read_status
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_federation_presence_update(socket, payload) when is_map(payload) do
    server_id = payload[:server_id] || payload["server_id"]

    if is_integer(server_id) and socket.assigns[:active_server_id] == server_id do
      remote_actor_id = payload[:remote_actor_id] || payload["remote_actor_id"]

      if is_integer(remote_actor_id) do
        existing = socket.assigns[:federation_presence] || %{}

        presence_entry = %{
          remote_actor_id: remote_actor_id,
          handle: payload[:handle] || payload["handle"] || "@remote",
          label: payload[:label] || payload["label"] || "@remote",
          avatar_url: payload[:avatar_url] || payload["avatar_url"],
          status: payload[:status] || payload["status"] || "offline",
          activities: payload[:activities] || payload["activities"] || [],
          updated_at: payload[:updated_at] || payload["updated_at"] || DateTime.utc_now()
        }

        {:noreply,
         Phoenix.Component.assign(
           socket,
           :federation_presence,
           Map.put(existing, remote_actor_id, presence_entry)
         )}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_message_pinned(socket, message) do
    if selected_conversation_matches?(socket, message.conversation_id) do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id do
            %{
              msg
              | is_pinned: true,
                pinned_at: message.pinned_at,
                pinned_by_id: message.pinned_by_id
            }
          else
            msg
          end
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_message_unpinned(socket, message) do
    if selected_conversation_matches?(socket, message.conversation_id) do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id do
            %{msg | is_pinned: false, pinned_at: nil, pinned_by_id: nil}
          else
            msg
          end
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_reaction_added(socket, reaction) do
    if selected_conversation_matches?(socket, reaction.message.conversation_id) do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == reaction.message.id do
            existing_reaction =
              Enum.find(msg.reactions, fn r ->
                r.user_id == reaction.user_id and r.emoji == reaction.emoji
              end)

            if existing_reaction do
              msg
            else
              %{msg | reactions: msg.reactions ++ [reaction]}
            end
          else
            msg
          end
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_reaction_removed(socket, reaction) do
    if selected_conversation_matches?(socket, reaction.message.conversation_id) do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == reaction.message.id do
            reactions = Enum.reject(msg.reactions, &(&1.id == reaction.id))
            %{msg | reactions: reactions}
          else
            msg
          end
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_message_link_preview_updated(socket, updated_message) do
    if selected_conversation_matches?(socket, updated_message.conversation_id) do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == updated_message.id do
            %{msg | link_preview: updated_message.link_preview}
          else
            msg
          end
        end)

      {:noreply, Phoenix.Component.assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_notification_count_updated(socket, new_count) do
    {:noreply, Phoenix.Component.assign(socket, :notification_count, new_count)}
  end

  defp selected_conversation_matches?(socket, conversation_id) when is_integer(conversation_id) do
    socket.assigns.conversation.selected &&
      socket.assigns.conversation.selected.id == conversation_id
  end

  defp selected_conversation_matches?(_socket, _conversation_id), do: false
end
