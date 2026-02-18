defmodule ElektrineChatWeb.MobileChannel do
  @moduledoc """
  Real-time channel for chat/auth mobile clients.
  """
  use ElektrineChatWeb, :channel

  alias Elektrine.Accounts
  alias Elektrine.PubSubTopics
  alias ElektrineChat, as: Messaging

  @impl true
  def join("mobile:user", _params, socket) do
    user_id = socket.assigns.user_id

    conversations = Messaging.list_conversations(user_id)

    Enum.each(conversations, fn conversation ->
      PubSubTopics.subscribe(PubSubTopics.conversation(conversation.id))
    end)

    send(self(), :after_join)

    {:ok, assign(socket, :joined_conversations, MapSet.new(Enum.map(conversations, & &1.id)))}
  end

  def join("mobile:" <> _other, _params, _socket), do: {:error, %{reason: "invalid_topic"}}

  @impl true
  def handle_info(:after_join, socket) do
    counts = Messaging.get_all_chat_unread_counts(socket.assigns.user_id)
    push(socket, "chat:unread_counts", %{counts: counts})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_chat_message, message}, socket) do
    push(socket, "chat:new_message", format_message(message))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message_updated, message}, socket) do
    push(socket, "chat:message_updated", format_message(message))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message_deleted, message_id}, socket) do
    push(socket, "chat:message_deleted", %{message_id: message_id})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_reaction_added, message_id, reaction}, socket) do
    push(socket, "chat:reaction_added", %{
      message_id: message_id,
      reaction: %{
        id: reaction.id,
        emoji: reaction.emoji,
        user_id: reaction.user_id
      }
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_reaction_removed, message_id, user_id, emoji}, socket) do
    push(socket, "chat:reaction_removed", %{
      message_id: message_id,
      user_id: user_id,
      emoji: emoji
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_typing, conversation_id, user_id, username}, socket) do
    push(socket, "chat:user_typing", %{
      conversation_id: conversation_id,
      user_id: user_id,
      username: username
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_stopped_typing, conversation_id, user_id}, socket) do
    push(socket, "chat:user_stopped_typing", %{
      conversation_id: conversation_id,
      user_id: user_id
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:read_receipt, conversation_id, user_id, message_id}, socket) do
    push(socket, "chat:read_receipt", %{
      conversation_id: conversation_id,
      user_id: user_id,
      message_id: message_id
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("ping", _payload, socket), do: {:reply, {:ok, %{pong: true}}, socket}

  @impl true
  def handle_in("chat:join_conversation", %{"conversation_id" => conv_id_raw}, socket) do
    user_id = socket.assigns.user_id

    with {:ok, conv_id} <- parse_int(conv_id_raw),
         member when not is_nil(member) <- Messaging.get_conversation_member(conv_id, user_id) do
      joined = socket.assigns[:joined_conversations] || MapSet.new()

      if not MapSet.member?(joined, conv_id) do
        PubSubTopics.subscribe(PubSubTopics.conversation(conv_id))
      end

      {:reply, :ok, assign(socket, :joined_conversations, MapSet.put(joined, conv_id))}
    else
      nil ->
        {:reply, {:error, %{reason: "not_member"}}, socket}

      _ ->
        {:reply, {:error, %{reason: "invalid_conversation_id"}}, socket}
    end
  end

  @impl true
  def handle_in("chat:typing", %{"conversation_id" => conv_id_raw}, socket) do
    user_id = socket.assigns.user_id

    with {:ok, conv_id} <- parse_int(conv_id_raw),
         member when not is_nil(member) <- Messaging.get_conversation_member(conv_id, user_id),
         user <- Accounts.get_user!(user_id) do
      topic = PubSubTopics.conversation(conv_id)

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        topic,
        {:user_typing, conv_id, user_id, user.username}
      )

      {:noreply, socket}
    else
      _ -> {:reply, {:error, %{reason: "not_member"}}, socket}
    end
  end

  @impl true
  def handle_in("chat:stop_typing", %{"conversation_id" => conv_id_raw}, socket) do
    user_id = socket.assigns.user_id

    with {:ok, conv_id} <- parse_int(conv_id_raw),
         member when not is_nil(member) <- Messaging.get_conversation_member(conv_id, user_id) do
      topic = PubSubTopics.conversation(conv_id)
      Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:user_stopped_typing, conv_id, user_id})
      {:noreply, socket}
    else
      _ -> {:reply, {:error, %{reason: "not_member"}}, socket}
    end
  end

  @impl true
  def handle_in(
        "chat:read_message",
        %{"conversation_id" => conv_id_raw, "message_id" => msg_id_raw},
        socket
      ) do
    user_id = socket.assigns.user_id

    with {:ok, conv_id} <- parse_int(conv_id_raw),
         {:ok, msg_id} <- parse_int(msg_id_raw),
         member when not is_nil(member) <- Messaging.get_conversation_member(conv_id, user_id) do
      Messaging.mark_chat_messages_read(conv_id, user_id, msg_id)

      topic = PubSubTopics.conversation(conv_id)
      Phoenix.PubSub.broadcast(Elektrine.PubSub, topic, {:read_receipt, conv_id, user_id, msg_id})

      {:noreply, socket}
    else
      _ -> {:reply, {:error, %{reason: "not_member"}}, socket}
    end
  end

  @impl true
  def handle_in("chat:get_unread_counts", _payload, socket) do
    counts = Messaging.get_all_chat_unread_counts(socket.assigns.user_id)
    {:reply, {:ok, %{counts: counts}}, socket}
  end

  defp format_message(message) do
    %{
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      media_urls: Map.get(message, :media_urls, []),
      media_metadata: Map.get(message, :media_metadata, %{}),
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      sender: format_sender(Map.get(message, :sender)),
      reply_to_id: Map.get(message, :reply_to_id),
      like_count: Map.get(message, :like_count, 0) || 0,
      reply_count: Map.get(message, :reply_count, 0) || 0,
      edited_at: Map.get(message, :edited_at),
      deleted_at: Map.get(message, :deleted_at),
      created_at: Map.get(message, :inserted_at)
    }
  end

  defp format_sender(nil), do: nil
  defp format_sender(%Ecto.Association.NotLoaded{}), do: nil

  defp format_sender(sender) do
    %{
      id: sender.id,
      username: sender.username,
      avatar: sender.avatar
    }
  end

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error
end
