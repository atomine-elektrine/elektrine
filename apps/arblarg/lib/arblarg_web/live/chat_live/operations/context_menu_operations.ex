defmodule ArblargWeb.ChatLive.Operations.ContextMenuOperations do
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
    conversation = find_by_id(socket.assigns.conversation.list, conversation_id)

    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | conversation: conversation,
         selected_text: nil,
         position: %{x: x, y: y}
     })}
  end

  def handle_event("show_context_menu", %{"conversation_id" => conversation_id}, socket) do
    conversation = find_by_id(socket.assigns.conversation.list, conversation_id)

    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | conversation: conversation,
         selected_text: nil
     })}
  end

  def handle_event("hide_context_menu", _params, socket) do
    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | conversation: nil,
         selected_text: nil
     })}
  end

  def handle_event(
        "show_message_context_menu",
        %{"message_id" => message_id, "x" => x, "y" => y} = params,
        socket
      ) do
    message = find_by_id(socket.assigns.messages, message_id)

    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | message: message,
         selected_text: selected_text(params),
         position: %{x: x, y: y}
     })}
  end

  def handle_event("show_message_context_menu", %{"message_id" => message_id}, socket) do
    message = find_by_id(socket.assigns.messages, message_id)

    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | message: message,
         selected_text: nil
     })}
  end

  def handle_event("hide_message_context_menu", _params, socket) do
    {:noreply,
     assign(socket, :context_menu, %{
       socket.assigns.context_menu
       | message: nil,
         selected_text: nil
     })}
  end

  defp find_by_id(items, id) when is_integer(id) do
    Enum.find(items, &(&1.id == id))
  end

  defp find_by_id(items, id) do
    case Integer.parse(to_string(id)) do
      {parsed_id, ""} when parsed_id > 0 -> Enum.find(items, &(&1.id == parsed_id))
      _ -> nil
    end
  end

  defp selected_text(%{"selected_text" => text}) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp selected_text(_params), do: nil
end
