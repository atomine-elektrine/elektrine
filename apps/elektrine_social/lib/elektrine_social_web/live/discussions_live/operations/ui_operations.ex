defmodule ElektrineSocialWeb.DiscussionsLive.Operations.UiOperations do
  @moduledoc """
  Handles all UI-related operations: modals, navigation, view switching, sorting.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Elektrine.Utils.SafeConvert
  alias ElektrineSocialWeb.DiscussionsLive.Operations.SortHelpers

  def handle_event("switch_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, :current_view, view)}
  end

  def handle_event("filter_by_hashtag", %{"hashtag" => hashtag}, socket) do
    # Filter posts by hashtag
    filtered_posts =
      Enum.filter(socket.assigns.discussion_posts, fn post ->
        post.hashtags && Enum.any?(post.hashtags, &(&1.name == hashtag))
      end)

    {:noreply,
     socket
     |> assign(:filtered_hashtag, hashtag)
     |> assign(:discussion_posts, filtered_posts)
     |> put_flash(:info, "Showing posts with ##{hashtag}")}
  end

  def handle_event("set_sort", %{"sort" => sort_by}, socket) do
    normalized_sort = SortHelpers.normalize_sort(sort_by)

    if socket.assigns.sort_by != normalized_sort do
      # Reload posts with new sorting
      posts = SortHelpers.load_posts(socket.assigns.community.id, normalized_sort, limit: 20)

      {:noreply,
       socket
       |> assign(:sort_by, normalized_sort)
       |> assign(:discussion_posts, posts)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore_community_preferences", params, socket) do
    restored_view = normalize_community_view(params["view"], socket.assigns.current_view)
    restored_sort = SortHelpers.normalize_sort(params["sort"])

    updated_socket =
      socket
      |> assign(:current_view, restored_view)
      |> assign(:community_preferences_restored, true)

    cond do
      restored_sort == socket.assigns.sort_by ->
        {:noreply, updated_socket}

      socket.assigns.loading_community ->
        {:noreply, assign(updated_socket, :sort_by, restored_sort)}

      true ->
        posts = SortHelpers.load_posts(socket.assigns.community.id, restored_sort, limit: 20)

        {:noreply,
         updated_socket
         |> assign(:sort_by, restored_sort)
         |> assign(:discussion_posts, posts)}
    end
  end

  def handle_event("report_discussion", %{"message_id" => message_id}, socket) do
    with {:ok, message_id} <- parse_positive_int(message_id),
         post when not is_nil(post) <-
           Enum.find(socket.assigns.discussion_posts, &(&1.id == message_id)) do
      {:noreply, open_report_modal(socket, message_id, post)}
    else
      _ -> {:noreply, socket}
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

  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    # Navigate to the original content location
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("copy_link", %{"message_id" => message_id}, socket) do
    path =
      case SafeConvert.parse_id(message_id) do
        {:ok, message_id} ->
          post = Enum.find(socket.assigns.discussion_posts || [], &(&1.id == message_id))

          title = if post, do: post.title, else: nil
          Elektrine.Paths.discussion_post_path(socket.assigns.community.name, message_id, title)

        {:error, _reason} ->
          Elektrine.Paths.discussion_path(socket.assigns.community.name)
      end

    discussion_url = ElektrineWeb.Endpoint.url() <> path

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: discussion_url})
     |> put_flash(:info, "Discussion link copied to clipboard!")}
  end

  def handle_event("view_original_context", %{"message_id" => original_message_id}, socket) do
    with {:ok, original_message_id} <- parse_positive_int(original_message_id),
         %{} = message <- Elektrine.Repo.get(Elektrine.Social.Message, original_message_id) do
      {:noreply,
       navigate_to_original_context(socket, Elektrine.Repo.preload(message, :conversation))}
    else
      _ -> {:noreply, notify_error(socket, "Original content not found")}
    end
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("stop_event", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("stop_propagation", _params, socket) do
    # No-op event to prevent click propagation to parent card
    {:noreply, socket}
  end

  def handle_event("noop", _params, socket) do
    # No-op event to prevent click propagation to parent card
    {:noreply, socket}
  end

  def handle_event("close_dropdown", _params, socket) do
    # Just acknowledge the event - dropdown will close automatically
    {:noreply, socket}
  end

  def handle_event("update", _params, socket) do
    # No-op - poll data is read directly from form params on submit
    {:noreply, socket}
  end

  # Image Modal Operations
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
       |> assign(:modal_post, find_modal_post(params["post_id"], socket))}
    else
      _ -> {:noreply, notify_error(socket, "Unable to open image")}
    end
  end

  # close_image_modal / next_image / prev_image are delegated to the shared
  # ElektrineSocialWeb.TimelineLive.Operations.ImageOperations via the router,
  # since they only operate on the canonical modal-state assigns.

  def handle_event("next_media_post", _params, socket) do
    navigate_to_media_post(socket, :next)
  end

  def handle_event("prev_media_post", _params, socket) do
    navigate_to_media_post(socket, :prev)
  end

  defp navigate_to_media_post(socket, direction) do
    modal_post = socket.assigns[:modal_post]

    discussion_posts =
      (socket.assigns[:discussion_posts] || []) ++ (socket.assigns[:pinned_posts] || [])

    if is_nil(modal_post) or Enum.empty?(discussion_posts) do
      {:noreply, socket}
    else
      # Find posts with media
      media_posts =
        Enum.filter(discussion_posts, fn post ->
          media_urls = post.media_urls || []
          media_urls != []
        end)

      # Find current post index in media_posts
      current_index = Enum.find_index(media_posts, fn post -> post.id == modal_post.id end)

      if is_nil(current_index) do
        {:noreply, socket}
      else
        # Calculate new index
        total = length(media_posts)

        new_index =
          case direction do
            :next -> rem(current_index + 1, total)
            :prev -> rem(current_index - 1 + total, total)
          end

        new_post = Enum.at(media_posts, new_index)
        new_images = new_post.media_urls || []
        new_url = List.first(new_images)

        {:noreply,
         socket
         |> assign(:modal_post, new_post)
         |> assign(:modal_images, new_images)
         |> assign(:modal_image_index, 0)
         |> assign(:modal_image_url, new_url)}
      end
    end
  end

  # Private helpers

  defp open_report_modal(socket, message_id, post) do
    report_metadata = %{
      "sender_id" => post.sender_id,
      "community_id" => socket.assigns.community.id,
      "community_name" => socket.assigns.community.name,
      "content_preview" => ElektrineWeb.HtmlHelpers.plain_text_preview(post.content, 100),
      "title" => ElektrineWeb.HtmlHelpers.plain_text_content(post.title),
      "source" => "discussions"
    }

    socket
    |> assign(:show_report_modal, true)
    |> assign(:report_type, "message")
    |> assign(:report_id, message_id)
    |> assign(:report_metadata, report_metadata)
  end

  defp navigate_to_original_context(socket, message) do
    case message.conversation.type do
      "timeline" ->
        push_navigate(socket, to: Elektrine.Paths.post_path(message.id))

      "community" ->
        push_navigate(socket, to: Elektrine.Paths.post_path(message))

      _ ->
        push_navigate(socket, to: Elektrine.Paths.chat_path(message.conversation))
    end
  end

  defp find_modal_post(nil, _socket), do: nil

  defp find_modal_post(post_id, socket) do
    case parse_positive_int(post_id) do
      {:ok, post_id} ->
        posts = (socket.assigns[:discussion_posts] || []) ++ (socket.assigns[:pinned_posts] || [])
        Enum.find(posts, fn post -> post.id == post_id end)

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

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end

  defp normalize_community_view(view, fallback)

  defp normalize_community_view(view, _fallback)
       when view in ["posts", "members", "flairs", "queue", "bans", "log", "automod"],
       do: view

  defp normalize_community_view(_, fallback), do: fallback
end
