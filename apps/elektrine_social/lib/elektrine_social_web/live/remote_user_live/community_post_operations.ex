defmodule ElektrineSocialWeb.RemoteUserLive.CommunityPostOperations do
  @moduledoc """
  Community post composer and media upload events for the remote user
  profile LiveView.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [consume_uploaded_entries: 3, put_flash: 3]

  alias Elektrine.Social
  alias ElektrineSocialWeb.RemoteUserLive.PostState

  def handle_event("toggle_create_post", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_post, !socket.assigns.show_create_post)
     |> assign(:post_title, "")
     |> assign(:post_content, "")
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_attachments, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  def handle_event("update_post_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, :post_title, title)}
  end

  def handle_event("update_post_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :post_content, content)}
  end

  # Media upload handlers
  def handle_event("open_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, true)}
  end

  def handle_event("close_image_upload", _params, socket) do
    {:noreply, assign(socket, :show_image_upload_modal, false)}
  end

  def handle_event("validate_community_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload_community_images", params, socket) do
    user = socket.assigns.current_user

    # Capture alt texts from params
    alt_texts =
      params
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "alt_text_") end)
      |> Enum.flat_map(fn {key, value} ->
        case PostState.parse_non_negative_int(String.replace(key, "alt_text_", ""), nil) do
          index when is_integer(index) -> [{to_string(index), value}]
          nil -> []
        end
      end)
      |> Map.new()

    # Upload files
    uploaded_files =
      consume_uploaded_entries(socket, :community_attachments, fn %{path: path}, entry ->
        upload_struct = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Elektrine.Uploads.upload_timeline_attachment(upload_struct, user.id) do
          {:ok, metadata} ->
            {:ok, metadata}

          {:error, _reason} ->
            {:postpone, :error}
        end
      end)

    if Enum.empty?(uploaded_files) do
      {:noreply, put_flash(socket, :error, "Please select files to upload")}
    else
      uploaded_urls =
        uploaded_files
        |> Enum.map(&Map.get(&1, :key))
        |> Enum.filter(&is_binary/1)

      {:noreply,
       socket
       |> assign(:show_image_upload_modal, false)
       |> assign(:pending_media_urls, uploaded_urls)
       |> assign(:pending_media_attachments, uploaded_files)
       |> assign(:pending_media_alt_texts, alt_texts)
       |> put_flash(:info, "#{length(uploaded_urls)} file(s) added")}
    end
  end

  def handle_event("clear_pending_images", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_attachments, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  def handle_event("submit_post", %{"content" => content} = params, socket) do
    if PostState.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to post")}
    else
      title = Map.get(params, "title", "")
      content = String.trim(content)
      media_urls = socket.assigns.pending_media_urls
      media_attachments = socket.assigns.pending_media_attachments || []
      alt_texts = socket.assigns.pending_media_alt_texts
      has_media = !Enum.empty?(media_urls)

      if content == "" and not has_media do
        {:noreply, put_flash(socket, :error, "Post content or media is required")}
      else
        # Create a post that mentions/targets the community
        # The post will be federated to the community
        community = socket.assigns.remote_actor

        full_content =
          if title != "" do
            "**#{title}**\n\n#{content}"
          else
            content
          end

        # Build media metadata with alt texts
        media_metadata =
          Social.merge_post_media_metadata(%{"attachments" => media_attachments}, alt_texts)

        post_opts = [
          visibility: "public",
          community_actor_uri: community.uri
        ]

        # Add media if present
        post_opts =
          if has_media do
            post_opts
            |> Keyword.put(:media_urls, media_urls)
            |> Keyword.put(:media_metadata, media_metadata)
          else
            post_opts
          end

        case Elektrine.Social.create_timeline_post(
               socket.assigns.current_user.id,
               full_content,
               post_opts
             ) do
          {:ok, _post} ->
            {:noreply,
             socket
             |> assign(:show_create_post, false)
             |> assign(:post_title, "")
             |> assign(:post_content, "")
             |> assign(:pending_media_urls, [])
             |> assign(:pending_media_attachments, [])
             |> assign(:pending_media_alt_texts, %{})
             |> put_flash(
               :info,
               "Post created! It will be federated to #{community.display_name || community.username}"
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to create post")}
        end
      end
    end
  end

  # Upload error helper
  def error_to_string(:too_large), do: "File is too large (max 50MB)"
  def error_to_string(:too_many_files), do: "Too many files (max 4)"
  def error_to_string(:not_accepted), do: "Invalid file type"
  def error_to_string(err), do: "Upload error: #{inspect(err)}"
end
