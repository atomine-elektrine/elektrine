defmodule ElektrineWeb.TimelineLive.Operations.ImageOperations do
  @moduledoc """
  Handles image upload and modal operations for the timeline.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  # Cancels an upload for a specific file reference.
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :timeline_attachments, ref)}
  end

  # Opens the image upload modal.
  def handle_event("open_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, true)}
  end

  # Closes the image upload modal.
  def handle_event("close_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, false)}
  end

  # Clears all pending images and alt texts.
  def handle_event("clear_pending_images", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  # Opens the image modal with image URL, array of images, current index, and post data.
  def handle_event(
        "open_image_modal",
        %{"url" => url, "images" => images_json, "index" => index, "post_id" => post_id},
        socket
      ) do
    images = Jason.decode!(images_json)
    post_id_int = String.to_integer(post_id)
    modal_post = Enum.find(socket.assigns.timeline_posts, fn post -> post.id == post_id_int end)

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, String.to_integer(index))
     |> assign(:modal_post, modal_post)}
  end

  # Opens the image modal for Lemmy posts where URL is derived from images array.
  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index, "post_id" => post_id},
        socket
      ) do
    images = Jason.decode!(images_json)
    index_int = String.to_integer(index)
    url = Enum.at(images, index_int, List.first(images))

    post_id_int = String.to_integer(post_id)
    modal_post = Enum.find(socket.assigns.timeline_posts, fn post -> post.id == post_id_int end)

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, index_int)
     |> assign(:modal_post, modal_post)}
  end

  # Closes the image modal and resets modal state.
  def handle_event("close_image_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)}
  end

  # Navigates to the next image in the modal gallery.
  def handle_event("next_image", _params, socket) do
    new_index = rem(socket.assigns.modal_image_index + 1, length(socket.assigns.modal_images))
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  # Navigates to the previous image in the modal gallery.
  def handle_event("prev_image", _params, socket) do
    total = length(socket.assigns.modal_images)
    new_index = rem(socket.assigns.modal_image_index - 1 + total, total)
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  # Navigates to the next post with media in the timeline.
  def handle_event("next_media_post", _params, socket) do
    navigate_to_media_post(socket, :next)
  end

  # Navigates to the previous post with media in the timeline.
  def handle_event("prev_media_post", _params, socket) do
    navigate_to_media_post(socket, :prev)
  end

  # Validates timeline upload (no-op for live validation).
  def handle_event("validate_timeline_upload", _params, socket) do
    {:noreply, socket}
  end

  # Uploads timeline images with alt texts and stores them for later post creation.
  def handle_event("upload_timeline_images", params, socket) do
    user = socket.assigns.current_user

    alt_texts =
      params
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "alt_text_") end)
      |> Enum.map(fn {key, value} ->
        index = key |> String.replace("alt_text_", "") |> String.to_integer()
        {to_string(index), value}
      end)
      |> Map.new()

    uploaded_files =
      consume_uploaded_entries(socket, :timeline_attachments, fn %{path: path}, entry ->
        upload_struct = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Elektrine.Uploads.upload_timeline_attachment(upload_struct, user.id) do
          {:ok, metadata} ->
            {:ok, metadata.key}

          {:error, _reason} ->
            {:postpone, :error}
        end
      end)

    if Enum.empty?(uploaded_files) do
      {:noreply, put_flash(socket, :error, "Please select files to upload")}
    else
      {:noreply,
       socket
       |> assign(:show_image_upload_modal, false)
       |> assign(:pending_media_urls, uploaded_files)
       |> assign(:pending_media_alt_texts, alt_texts)
       |> put_flash(:info, "#{length(uploaded_files)} file(s) added")}
    end
  end

  defp navigate_to_media_post(socket, direction) do
    modal_post = socket.assigns[:modal_post]
    timeline_posts = socket.assigns[:timeline_posts] || []

    if is_nil(modal_post) or Enum.empty?(timeline_posts) do
      {:noreply, socket}
    else
      # Find posts with media
      media_posts =
        Enum.filter(timeline_posts, fn post ->
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
end
