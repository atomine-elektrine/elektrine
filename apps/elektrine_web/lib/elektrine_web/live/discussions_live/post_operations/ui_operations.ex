defmodule ElektrineWeb.DiscussionsLive.PostOperations.UIOperations do
  @moduledoc """
  Handles UI operations for discussion post detail view.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("stop_event", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("copy_discussion_link", %{"message_id" => message_id}, socket) do
    post_url =
      "#{ElektrineWeb.Endpoint.url()}/discussions/#{socket.assigns.community.name}/p/#{message_id}"

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: post_url})
     |> notify_info("Link copied to clipboard")}
  end

  def handle_event("copy_link", %{"message_id" => _message_id}, socket) do
    post = socket.assigns.post
    slug = Elektrine.Utils.Slug.discussion_url_slug(post.id, post.title)
    url = url(~p"/communities/#{socket.assigns.community.name}/post/#{slug}")

    {:noreply, push_event(socket, "copy_to_clipboard", %{text: url})}
  end

  def handle_event("report_discussion", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    post = socket.assigns.post

    report_metadata = %{
      "sender_id" => post.sender_id,
      "community_id" => socket.assigns.community.id,
      "community_name" => socket.assigns.community.name,
      "content_preview" => String.slice(post.content || "", 0, 100),
      "title" => post.title,
      "source" => "discussion_detail"
    }

    {:noreply,
     socket
     |> assign(:show_report_modal, true)
     |> assign(:report_type, "message")
     |> assign(:report_id, message_id)
     |> assign(:report_metadata, report_metadata)}
  end

  def handle_event("close_report_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_type, nil)
     |> assign(:report_id, nil)
     |> assign(:report_metadata, %{})}
  end

  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    images = Jason.decode!(images_json)
    index_int = String.to_integer(index)
    url = params["url"] || Enum.at(images, index_int, List.first(images))

    modal_post =
      if params["post_id"] do
        post_id = String.to_integer(params["post_id"])

        if socket.assigns.post.id == post_id do
          socket.assigns.post
        else
          nil
        end
      else
        socket.assigns.post
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
end
