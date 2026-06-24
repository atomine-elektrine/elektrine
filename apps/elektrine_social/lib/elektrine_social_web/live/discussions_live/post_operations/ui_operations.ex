defmodule ElektrineSocialWeb.DiscussionsLive.PostOperations.UIOperations do
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
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
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
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        {:noreply, open_report_modal(socket, message_id)}

      :error ->
        {:noreply, notify_error(socket, "Post not found")}
    end
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
    with {:ok, images} when is_list(images) <- Jason.decode(images_json),
         {:ok, index_int} <- parse_non_negative_int(index) do
      url = params["url"] || Enum.at(images, index_int, List.first(images))

      {:noreply,
       socket
       |> assign(:show_image_modal, true)
       |> assign(:modal_image_url, url)
       |> assign(:modal_images, images)
       |> assign(:modal_image_index, index_int)
       |> assign(:modal_post, modal_post(params["post_id"], socket))}
    else
      _ -> {:noreply, notify_error(socket, "Unable to open image")}
    end
  end

  # close_image_modal / next_image / prev_image are delegated to the shared
  # ElektrineSocialWeb.TimelineLive.Operations.ImageOperations via the post router,
  # since they only operate on the canonical modal-state assigns.

  defp open_report_modal(socket, message_id) do
    post = socket.assigns.post

    report_metadata = %{
      "sender_id" => post.sender_id,
      "community_id" => socket.assigns.community.id,
      "community_name" => socket.assigns.community.name,
      "content_preview" => ElektrineWeb.HtmlHelpers.plain_text_preview(post.content, 100),
      "title" => ElektrineWeb.HtmlHelpers.plain_text_content(post.title),
      "source" => "discussion_detail"
    }

    socket
    |> assign(:show_report_modal, true)
    |> assign(:report_type, "message")
    |> assign(:report_id, message_id)
    |> assign(:report_metadata, report_metadata)
  end

  defp modal_post(nil, socket), do: socket.assigns.post

  defp modal_post(post_id, socket) do
    case parse_positive_int(post_id) do
      {:ok, post_id} ->
        if socket.assigns.post.id == post_id, do: socket.assigns.post

      :error ->
        nil
    end
  end

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_non_negative_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :error
    end
  end
end
