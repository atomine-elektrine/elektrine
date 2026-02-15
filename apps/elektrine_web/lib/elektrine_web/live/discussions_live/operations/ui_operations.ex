defmodule ElektrineWeb.DiscussionsLive.Operations.UiOperations do
  @moduledoc """
  Handles all UI-related operations: modals, navigation, view switching, sorting.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias ElektrineWeb.DiscussionsLive.Operations.SortHelpers

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

  def handle_event("report_discussion", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    post = Enum.find(socket.assigns.discussion_posts, &(&1.id == message_id))

    if post do
      report_metadata = %{
        "sender_id" => post.sender_id,
        "community_id" => socket.assigns.community.id,
        "community_name" => socket.assigns.community.name,
        "content_preview" => String.slice(post.content || "", 0, 100),
        "title" => post.title,
        "source" => "discussions"
      }

      {:noreply,
       socket
       |> assign(:show_report_modal, true)
       |> assign(:report_type, "message")
       |> assign(:report_id, message_id)
       |> assign(:report_metadata, report_metadata)}
    else
      {:noreply, socket}
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
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("copy_link", %{"message_id" => message_id}, socket) do
    # Generate link to this specific discussion post
    community_hash = socket.assigns.community.hash || socket.assigns.community.id

    discussion_url =
      "#{ElektrineWeb.Endpoint.url()}/discussions/#{community_hash}#post-#{message_id}"

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: discussion_url})
     |> put_flash(:info, "Discussion link copied to clipboard!")}
  end

  def handle_event("view_original_context", %{"message_id" => original_message_id}, socket) do
    original_message_id = String.to_integer(original_message_id)

    # Try to determine where the original message is and navigate there
    case Elektrine.Repo.get(Elektrine.Messaging.Message, original_message_id) do
      nil ->
        {:noreply, notify_error(socket, "Original content not found")}

      message ->
        message = Elektrine.Repo.preload(message, :conversation)

        case message.conversation.type do
          "timeline" ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message.id}")}

          "community" ->
            # Use friendly URL with slug
            slug = Elektrine.Utils.Slug.discussion_url_slug(message.id, message.title)

            {:noreply,
             push_navigate(socket, to: ~p"/communities/#{message.conversation.name}/post/#{slug}")}

          _ ->
            # For chat/DM, go to chat
            {:noreply,
             push_navigate(socket,
               to: ~p"/chat/#{message.conversation.hash || message.conversation.id}"
             )}
        end
    end
  end

  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    post =
      Enum.find(
        (socket.assigns[:discussion_posts] || []) ++ (socket.assigns[:pinned_posts] || []),
        &(&1.id == String.to_integer(id))
      )

    if post do
      url = generate_discussion_url(socket.assigns.community, post)
      {:noreply, push_navigate(socket, to: url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
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
    images = Jason.decode!(images_json)
    index_int = String.to_integer(index)
    url = params["url"] || Enum.at(images, index_int, List.first(images))

    modal_post =
      if params["post_id"] do
        post_id = String.to_integer(params["post_id"])
        posts = (socket.assigns[:discussion_posts] || []) ++ (socket.assigns[:pinned_posts] || [])
        Enum.find(posts, fn post -> post.id == post_id end)
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

  defp generate_discussion_url(community, post) do
    community_name = community.name
    # Always use SEO-friendly URL with slug (falls back to just ID if no title)
    slug = Elektrine.Utils.Slug.discussion_url_slug(post.id, post.title)
    ~p"/communities/#{community_name}/post/#{slug}"
  end

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end
end
