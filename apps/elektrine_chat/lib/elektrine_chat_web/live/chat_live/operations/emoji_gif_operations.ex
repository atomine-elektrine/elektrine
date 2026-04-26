defmodule ElektrineChatWeb.ChatLive.Operations.EmojiGifOperations do
  @moduledoc """
  Handles emoji picker operations.
  Extracted from ChatLive.Home.
  """

  import Phoenix.Component

  def handle_event("toggle_emoji_picker", _params, socket) do
    {:noreply,
     assign(
       socket,
       :ui,
       Map.put(socket.assigns.ui, :show_emoji_picker, !socket.assigns.ui.show_emoji_picker)
     )}
  end

  def handle_event("insert_emoji", %{"emoji" => emoji}, socket) do
    current_message = socket.assigns.message.new_message
    updated_message = "#{current_message}#{emoji}"

    {:noreply,
     socket
     |> assign(:message, %{socket.assigns.message | new_message: updated_message})
     |> assign(:ui, Map.put(socket.assigns.ui, :show_emoji_picker, false))}
  end

  def handle_event("emoji_search", %{"value" => query}, socket) do
    {:noreply, assign(socket, :search, %{socket.assigns.search | emoji_query: query})}
  end

  def handle_event("emoji_search", %{"emoji_query" => query}, socket) do
    {:noreply, assign(socket, :search, %{socket.assigns.search | emoji_query: query})}
  end

  def handle_event("emoji_search", %{"value" => query}, socket) do
    {:noreply, assign(socket, :search, %{socket.assigns.search | emoji_query: query})}
  end

  def handle_event("emoji_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :search, %{socket.assigns.search | emoji_tab: tab})}
  end
end
