defmodule ElektrineWeb.ChatLive.Operations.EmojiGifOperations do
  @moduledoc """
  Handles emoji picker and GIF search operations.
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

  def handle_event("toggle_gif_picker", _params, socket) do
    {:noreply,
     assign(
       socket,
       :ui,
       Map.put(socket.assigns.ui, :show_gif_picker, !socket.assigns.ui.show_gif_picker)
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

  def handle_event("search_gifs", %{"query" => query}, socket) do
    gifs =
      if String.length(query) >= 2 do
        # Search GIFs using Giphy API
        case Elektrine.Giphy.search_gifs(query) do
          {:ok, results} -> results
          {:error, _} -> []
        end
      else
        # Return trending GIFs
        case Elektrine.Giphy.trending_gifs() do
          {:ok, results} -> results
          {:error, _} -> []
        end
      end

    {:noreply, assign(socket, :gif_results, gifs)}
  end

  def handle_event("insert_gif", %{"url" => gif_url}, socket) do
    current_message = socket.assigns.message.new_message
    updated_message = "#{current_message}\n#{gif_url}"

    {:noreply,
     socket
     |> assign(:message, %{socket.assigns.message | new_message: updated_message})
     |> assign(:show_gif_picker, false)}
  end

  def handle_event("emoji_search", %{"emoji_query" => query}, socket) do
    {:noreply, assign(socket, :search, %{socket.assigns.search | emoji_query: query})}
  end

  def handle_event("emoji_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :search, %{socket.assigns.search | emoji_tab: tab})}
  end
end
