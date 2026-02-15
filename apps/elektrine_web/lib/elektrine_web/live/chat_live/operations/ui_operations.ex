defmodule ElektrineWeb.ChatLive.Operations.UIOperations do
  @moduledoc """
  Handles UI state: modals, dropdowns, search, emoji picker, etc.
  Extracted from ChatLive.Home.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  def handle_event("close_dropdown", _params, socket) do
    # Just acknowledge the event - dropdown will close automatically
    {:noreply, socket}
  end

  def handle_event("toggle_mobile_search", _params, socket) do
    {:noreply, assign(socket, :show_mobile_search, !socket.assigns.show_mobile_search)}
  end

  def handle_event("show_emoji_picker", _params, socket) do
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

  def handle_event("stop_event", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("show_message_search", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_message_search, true))}
  end

  def handle_event("hide_message_search", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_message_search, false))}
  end

  def handle_event("ignore", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("view_original_context", %{"message_id" => message_id}, socket) do
    {:noreply, push_event(socket, "scroll_to_message", %{message_id: message_id})}
  end

  def handle_event("show_report_modal", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_report_modal, true))
     |> assign(:report_type, type)
     |> assign(:report_id, String.to_integer(id))}
  end

  def handle_event("close_report_modal", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_report_modal, false))}
  end

  # Image Modal Operations
  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    images = Jason.decode!(images_json)
    index_int = String.to_integer(index)
    url = params["url"] || Enum.at(images, index_int, List.first(images))

    # For chat messages, the post context is the message itself
    modal_post =
      if params["message_id"] do
        message_id = String.to_integer(params["message_id"])
        Enum.find(socket.assigns.messages, fn msg -> msg.id == message_id end)
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, index_int)
     |> assign(:modal_post, modal_post)}
  end

  def handle_event("close_image_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)}
  end

  def handle_event("next_image", _params, socket) do
    total = length(socket.assigns.modal_images)

    if total > 0 do
      new_index = rem(socket.assigns.modal_image_index + 1, total)
      new_url = Enum.at(socket.assigns.modal_images, new_index)

      {:noreply,
       socket
       |> assign(:modal_image_index, new_index)
       |> assign(:modal_image_url, new_url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_image", _params, socket) do
    total = length(socket.assigns.modal_images)

    if total > 0 do
      new_index = rem(socket.assigns.modal_image_index - 1 + total, total)
      new_url = Enum.at(socket.assigns.modal_images, new_index)

      {:noreply,
       socket
       |> assign(:modal_image_index, new_index)
       |> assign(:modal_image_url, new_url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("next_media_post", _params, socket) do
    navigate_to_media_message(socket, :next)
  end

  def handle_event("prev_media_post", _params, socket) do
    navigate_to_media_message(socket, :prev)
  end

  defp navigate_to_media_message(socket, direction) do
    modal_post = socket.assigns[:modal_post]
    messages = socket.assigns[:messages] || []

    if is_nil(modal_post) or Enum.empty?(messages) do
      {:noreply, socket}
    else
      # Find messages with media
      media_messages =
        Enum.filter(messages, fn msg ->
          media_urls = msg.media_urls || []
          media_urls != []
        end)

      # Find current message index in media_messages
      current_index = Enum.find_index(media_messages, fn msg -> msg.id == modal_post.id end)

      if is_nil(current_index) do
        {:noreply, socket}
      else
        # Calculate new index
        total = length(media_messages)

        new_index =
          case direction do
            :next -> rem(current_index + 1, total)
            :prev -> rem(current_index - 1 + total, total)
          end

        new_message = Enum.at(media_messages, new_index)
        new_images = new_message.media_urls || []
        new_url = List.first(new_images)

        {:noreply,
         socket
         |> assign(:modal_post, new_message)
         |> assign(:modal_images, new_images)
         |> assign(:modal_image_index, 0)
         |> assign(:modal_image_url, new_url)}
      end
    end
  end
end
