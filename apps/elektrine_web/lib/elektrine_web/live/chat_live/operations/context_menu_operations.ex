defmodule ElektrineWeb.ChatLive.Operations.ContextMenuOperations do
  @moduledoc """
  Handles context menu operations: show/hide conversation and message context menus.
  Extracted from ChatLive.Home.
  """

  import Phoenix.Component

  def handle_event(
        "show_context_menu",
        %{"conversation_id" => conversation_id, "x" => x, "y" => y},
        socket
      ) do
    conversation_id =
      if is_binary(conversation_id), do: String.to_integer(conversation_id), else: conversation_id

    conversation = Enum.find(socket.assigns.conversation.list, &(&1.id == conversation_id))

    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | conversation: conversation,
         position: %{x: x, y: y}
     })}
  end

  def handle_event("show_context_menu", %{"conversation_id" => conversation_id}, socket) do
    conversation_id =
      if is_binary(conversation_id), do: String.to_integer(conversation_id), else: conversation_id

    conversation = Enum.find(socket.assigns.conversation.list, &(&1.id == conversation_id))

    {:noreply,
     assign(socket, :context_menu, %{socket.assigns.context_menu | conversation: conversation})}
  end

  def handle_event("hide_context_menu", _params, socket) do
    {:noreply, assign(socket, :context_menu, %{socket.assigns.context_menu | conversation: nil})}
  end

  def handle_event(
        "show_message_context_menu",
        %{"message_id" => message_id, "x" => x, "y" => y},
        socket
      ) do
    message_id = if is_binary(message_id), do: String.to_integer(message_id), else: message_id
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | message: message,
         position: %{x: x, y: y}
     })}
  end

  def handle_event("show_message_context_menu", %{"message_id" => message_id}, socket) do
    message_id = if is_binary(message_id), do: String.to_integer(message_id), else: message_id
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    {:noreply, assign(socket, :context_menu, %{socket.assigns.context_menu | message: message})}
  end

  def handle_event("hide_message_context_menu", _params, socket) do
    {:noreply, assign(socket, :context_menu, %{socket.assigns.context_menu | message: nil})}
  end
end
