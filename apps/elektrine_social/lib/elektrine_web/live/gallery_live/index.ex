defmodule ElektrineWeb.GalleryLive.Index do
  use ElektrineSocialWeb, :live_view
  alias Elektrine.{Messaging, Social}
  alias Elektrine.PubSubTopics
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.Components.Platform.ENav

  import ElektrineWeb.HtmlHelpers,
    only: [actor_display_name_text: 1, plain_text_content: 1, render_display_name_with_emojis: 2]

  import ElektrineWeb.Live.Helpers.PostStateHelpers
  import ElektrineWeb.Live.NotificationHelpers

  @gallery_page_size 60

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) do
      PubSubTopics.subscribe(PubSubTopics.timeline_public())

      if user do
        PubSubTopics.subscribe("gallery:all")
      end

      send(self(), :load_gallery_data)
    end

    socket =
      socket
      |> assign(:page_title, "Gallery")
      |> assign(:gallery_posts, [])
      |> assign(:current_filter, "discover")
      |> assign(:gallery_search, "")
      |> assign(:gallery_sort, "fresh")
      |> assign(:software_filter, "all")
      |> assign(:user_likes, MapSet.new())
      |> assign(:user_saved_posts, MapSet.new())
      |> assign(:show_upload_modal, false)
      |> assign(:upload_title, "")
      |> assign(:upload_description, "")
      |> assign(:upload_category, "photography")
      |> assign(:upload_visibility, "public")
      |> assign(:filtered_posts, [])
      |> assign(:gallery_filter, "all")
      |> assign(:user_gallery_stats, nil)
      |> assign(:recent_uploads, [])
      |> assign(:top_upload, nil)
      |> assign(:suggested_photographers, [])
      |> assign(:trending_tags, [])
      |> assign(:uploading, false)
      |> assign(:loading_more, false)
      |> assign(:loading_gallery, true)
      |> assign(:end_of_feed, false)
      |> assign(:show_image_modal, false)
      |> assign(:modal_image_url, nil)
      |> assign(:modal_images, [])
      |> assign(:modal_image_index, 0)
      |> assign(:modal_post, nil)
      |> assign(:modal_is_liked, false)

    socket =
      if user do
        allow_upload(socket, :gallery_image,
          accept: ~w(.jpg .jpeg .png .gif .webp),
          max_entries: 1,
          max_file_size: 10_000_000
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    if socket.assigns.current_filter == filter do
      {:noreply, socket}
    else
      posts = get_gallery_feed(filter, socket.assigns.current_user)

      {user_likes, user_saved_posts} =
        load_gallery_engagement_state(socket.assigns[:current_user], posts)

      {:noreply,
       socket
       |> assign(:current_filter, filter)
       |> assign(:gallery_posts, posts)
       |> assign(:user_likes, user_likes)
       |> assign(:user_saved_posts, user_saved_posts)
       |> assign(:loading_more, false)
       |> assign(:end_of_feed, length(posts) < @gallery_page_size)
       |> apply_gallery_filter()}
    end
  end

  def handle_event("set_software_filter", %{"software" => software}, socket) do
    if socket.assigns.software_filter == software do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:software_filter, software) |> apply_gallery_filter()}
    end
  end

  def handle_event("set_gallery_filter", %{"filter" => filter}, socket) do
    if socket.assigns.gallery_filter == filter do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:gallery_filter, filter) |> apply_gallery_filter()}
    end
  end

  def handle_event("set_gallery_sort", %{"sort" => sort}, socket) do
    if socket.assigns.gallery_sort == sort do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:gallery_sort, sort) |> apply_gallery_filter()}
    end
  end

  def handle_event("search_gallery", %{"query" => query}, socket) do
    {:noreply,
     socket |> assign(:gallery_search, String.trim(query || "")) |> apply_gallery_filter()}
  end

  def handle_event("clear_gallery_search", _params, socket) do
    {:noreply, socket |> assign(:gallery_search, "") |> apply_gallery_filter()}
  end

  def handle_event("apply_tag_search", %{"tag" => tag}, socket) do
    normalized_tag = tag |> to_string() |> String.trim_leading("#") |> String.trim()
    {:noreply, socket |> assign(:gallery_search, normalized_tag) |> apply_gallery_filter()}
  end

  def handle_event("toggle_upload_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_upload_modal, !socket.assigns.show_upload_modal)
     |> assign(:upload_title, "")
     |> assign(:upload_description, "")
     |> assign(:upload_category, "photography")}
  end

  def handle_event("update_upload_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, :upload_title, title)}
  end

  def handle_event("update_upload_description", %{"description" => description}, socket) do
    {:noreply, assign(socket, :upload_description, description)}
  end

  def handle_event("update_upload_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :upload_category, category)}
  end

  def handle_event("update_upload_visibility", %{"visibility" => visibility}, socket) do
    {:noreply, assign(socket, :upload_visibility, visibility)}
  end

  def handle_event("cancel_upload", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_upload_modal, false)
     |> assign(:upload_title, "")
     |> assign(:upload_description, "")
     |> assign(:upload_category, "photography")}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_gallery_photo", _params, socket) do
    require Logger
    user_id = socket.assigns.current_user.id
    Logger.info("Starting gallery upload for user #{user_id}")
    socket = assign(socket, :uploading, true)

    uploaded_files =
      consume_uploaded_entries(socket, :gallery_image, fn %{path: path}, entry ->
        upload_struct = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Elektrine.Uploads.upload_gallery_photo(upload_struct, user_id) do
          {:ok, metadata} ->
            Logger.info("Image uploaded successfully: #{metadata.key}")
            {:ok, metadata}

          {:error, reason} ->
            Logger.error("Image upload failed: #{inspect(reason)}")
            {:postpone, :error}
        end
      end)

    Logger.info("Uploaded files: #{inspect(uploaded_files)}")

    if Enum.empty?(uploaded_files) do
      {:noreply, put_flash(socket, :error, "Please select an image to upload")}
    else
      uploaded_urls =
        uploaded_files
        |> Enum.map(&Map.get(&1, :key))
        |> Enum.filter(&is_binary/1)

      image_url = hd(uploaded_urls)

      media_metadata =
        Social.merge_post_media_metadata(%{"attachments" => uploaded_files})

      case Social.create_timeline_post(
             user_id,
             socket.assigns.upload_description || "",
             visibility: socket.assigns.upload_visibility,
             media_urls: [image_url],
             media_metadata: media_metadata,
             title: socket.assigns.upload_title,
             post_type: "gallery",
             category: socket.assigns.upload_category
           ) do
        {:ok, gallery_post} ->
          Logger.info("Gallery post created: #{gallery_post.id}")
          gallery_post = Elektrine.Repo.preload(gallery_post, sender: [:profile])

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "gallery:all",
            {:new_gallery_post, gallery_post}
          )

          {:noreply,
           socket
           |> assign(:show_upload_modal, false)
           |> assign(:upload_title, "")
           |> assign(:upload_description, "")
           |> assign(:upload_category, "photography")
           |> assign(:uploading, false)
           |> put_flash(:info, "Photo uploaded successfully!")}

        {:error, changeset} ->
          Logger.error("Failed to create gallery post: #{inspect(changeset)}")

          {:noreply,
           socket |> assign(:uploading, false) |> put_flash(:error, "Failed to upload photo")}
      end
    end
  end

  def handle_event("like_photo", %{"photo_id" => photo_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      photo_id = String.to_integer(photo_id)
      currently_liked = MapSet.member?(socket.assigns.user_likes, photo_id)

      if currently_liked do
        case Social.unlike_post(user_id, photo_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update(:user_likes, &MapSet.delete(&1, photo_id))
             |> update(:gallery_posts, fn posts ->
               update_gallery_like_count(posts, photo_id, -1)
             end)
             |> maybe_remove_from_collection_filter("liked", photo_id)
             |> apply_gallery_filter()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to unlike photo")}
        end
      else
        case Social.like_post(user_id, photo_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update(:user_likes, &MapSet.put(&1, photo_id))
             |> update(:gallery_posts, fn posts ->
               update_gallery_like_count(posts, photo_id, 1)
             end)
             |> apply_gallery_filter()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to like photo")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like photos")}
    end
  end

  def handle_event("save_post", %{"photo_id" => photo_id}, socket) do
    handle_event("save_post", %{"message_id" => photo_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      photo_id = if is_binary(message_id), do: String.to_integer(message_id), else: message_id

      case Social.save_post(user_id, photo_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> update(:user_saved_posts, &MapSet.put(&1, photo_id))
           |> notify_info("Saved to your collection")}

        {:error, _} ->
          {:noreply,
           socket
           |> update(:user_saved_posts, &MapSet.put(&1, photo_id))
           |> notify_info("Already saved")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to save photos")}
    end
  end

  def handle_event("unsave_post", %{"photo_id" => photo_id}, socket) do
    handle_event("unsave_post", %{"message_id" => photo_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      photo_id = if is_binary(message_id), do: String.to_integer(message_id), else: message_id

      case Social.unsave_post(user_id, photo_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> update(:user_saved_posts, &MapSet.delete(&1, photo_id))
           |> maybe_remove_from_collection_filter("saved", photo_id)
           |> apply_gallery_filter()
           |> notify_info("Removed from saved")}

        {:error, _} ->
          {:noreply,
           socket
           |> update(:user_saved_posts, &MapSet.delete(&1, photo_id))
           |> maybe_remove_from_collection_filter("saved", photo_id)
           |> apply_gallery_filter()}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("view_photo", %{"photo_id" => photo_id}, socket) do
    photo_id =
      if is_binary(photo_id) do
        String.to_integer(photo_id)
      else
        photo_id
      end

    photo = Enum.find(socket.assigns.filtered_posts, fn post -> post.id == photo_id end)

    if photo && photo.media_urls && photo.media_urls != [] do
      images = Enum.map(photo.media_urls, &Elektrine.Uploads.attachment_url/1)

      {:noreply,
       socket
       |> assign(:show_image_modal, true)
       |> assign(:modal_image_url, hd(images))
       |> assign(:modal_images, images)
       |> assign(:modal_image_index, 0)
       |> assign(:modal_post, photo)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "view_federated_photo",
        %{"activitypub_id" => activitypub_id} = _params,
        socket
      ) do
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(activitypub_id)}")}
  end

  def handle_event("load-more", _params, socket) do
    if socket.assigns.loading_more || socket.assigns.end_of_feed do
      {:noreply, socket}
    else
      current_posts = socket.assigns.gallery_posts

      before_timestamp =
        if Enum.empty?(current_posts) do
          nil
        else
          List.last(current_posts).inserted_at
        end

      socket = assign(socket, :loading_more, true)

      more_posts =
        get_gallery_feed(socket.assigns.current_filter, socket.assigns.current_user,
          before_timestamp: before_timestamp
        )

      existing_ids = MapSet.new(current_posts, & &1.id)
      more_posts = Enum.reject(more_posts, fn post -> MapSet.member?(existing_ids, post.id) end)
      end_of_feed = Enum.empty?(more_posts)

      {new_likes, new_saved_posts} =
        if socket.assigns[:current_user] && !Enum.empty?(more_posts) do
          load_gallery_engagement_state(socket.assigns.current_user, more_posts)
        else
          {MapSet.new(), MapSet.new()}
        end

      {:noreply,
       socket
       |> assign(:loading_more, false)
       |> assign(:end_of_feed, end_of_feed)
       |> assign(:user_likes, MapSet.union(socket.assigns.user_likes, new_likes))
       |> assign(
         :user_saved_posts,
         MapSet.union(socket.assigns.user_saved_posts, new_saved_posts)
       )
       |> update(:gallery_posts, fn posts -> posts ++ more_posts end)
       |> apply_gallery_filter()}
    end
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("follow_photographer", %{"user_id" => user_id}, socket) do
    if socket.assigns[:current_user] do
      current_user_id = socket.assigns.current_user.id
      photographer_id = String.to_integer(user_id)

      case Elektrine.Profiles.follow_user(current_user_id, photographer_id) do
        {:ok, _} ->
          updated_suggestions =
            Enum.reject(socket.assigns.suggested_photographers, &(&1.id == photographer_id))

          {:noreply,
           socket
           |> assign(:suggested_photographers, updated_suggestions)
           |> put_flash(:info, "Following photographer!")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to follow user")}
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    end
  end

  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    images = Jason.decode!(images_json)
    index_int = String.to_integer(index)
    url = params["url"] || Enum.at(images, index_int, List.first(images))

    {modal_post, is_liked} =
      if params["photo_id"] do
        photo_id = String.to_integer(params["photo_id"])
        post = Enum.find(socket.assigns.filtered_posts, fn post -> post.id == photo_id end)

        liked =
          if socket.assigns[:current_user] && post do
            result = Social.user_liked_post?(socket.assigns.current_user.id, photo_id)
            require Logger

            Logger.info(
              "Gallery modal: photo_id=#{photo_id}, user_id=#{socket.assigns.current_user.id}, liked=#{result}"
            )

            result
          else
            false
          end

        {post, liked}
      else
        {nil, false}
      end

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, index_int)
     |> assign(:modal_post, modal_post)
     |> assign(:modal_is_liked, is_liked)}
  end

  def handle_event("close_image_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)
     |> assign(:modal_is_liked, false)}
  end

  def handle_event("next_image", _params, socket) do
    total = length(socket.assigns.modal_images)

    if total > 0 do
      new_index = rem(socket.assigns.modal_image_index + 1, total)
      new_url = Enum.at(socket.assigns.modal_images, new_index)

      {:noreply,
       socket |> assign(:modal_image_index, new_index) |> assign(:modal_image_url, new_url)}
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
       socket |> assign(:modal_image_index, new_index) |> assign(:modal_image_url, new_url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("next_media_post", _params, socket) do
    current_post = socket.assigns.modal_post

    if current_post do
      posts = socket.assigns.filtered_posts
      current_index = Enum.find_index(posts, fn p -> p.id == current_post.id end) || 0
      next_index = rem(current_index + 1, length(posts))
      next_post = Enum.at(posts, next_index)

      if next_post do
        images = next_post.media_urls || []
        first_url = List.first(images)
        is_liked = MapSet.member?(socket.assigns.user_likes, next_post.id)

        {:noreply,
         socket
         |> assign(:modal_post, next_post)
         |> assign(:modal_images, images)
         |> assign(:modal_image_url, first_url)
         |> assign(:modal_image_index, 0)
         |> assign(:modal_is_liked, is_liked)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_media_post", _params, socket) do
    current_post = socket.assigns.modal_post

    if current_post do
      posts = socket.assigns.filtered_posts
      current_index = Enum.find_index(posts, fn p -> p.id == current_post.id end) || 0
      prev_index = rem(current_index - 1 + length(posts), length(posts))
      prev_post = Enum.at(posts, prev_index)

      if prev_post do
        images = prev_post.media_urls || []
        first_url = List.first(images)
        is_liked = MapSet.member?(socket.assigns.user_likes, prev_post.id)

        {:noreply,
         socket
         |> assign(:modal_post, prev_post)
         |> assign(:modal_images, images)
         |> assign(:modal_image_url, first_url)
         |> assign(:modal_image_index, 0)
         |> assign(:modal_is_liked, is_liked)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id

      photo_id =
        if is_binary(post_id) do
          String.to_integer(post_id)
        else
          post_id
        end

      is_currently_liked = Social.user_liked_post?(user_id, photo_id)

      if is_currently_liked do
        case Social.unlike_post(user_id, photo_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:modal_is_liked, false)
             |> update(:user_likes, &MapSet.delete(&1, photo_id))
             |> update(:gallery_posts, fn posts ->
               update_gallery_like_count(posts, photo_id, -1)
             end)
             |> update(:modal_post, fn post ->
               if post && post.id == photo_id do
                 %{post | like_count: max(0, (post.like_count || 0) - 1)}
               else
                 post
               end
             end)
             |> maybe_remove_from_collection_filter("liked", photo_id)
             |> apply_gallery_filter()
             |> notify_info("Removed like")}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:modal_is_liked, false)
             |> update(:user_likes, &MapSet.delete(&1, photo_id))}
        end
      else
        case Social.like_post(user_id, photo_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:modal_is_liked, true)
             |> update(:user_likes, &MapSet.put(&1, photo_id))
             |> update(:gallery_posts, fn posts ->
               update_gallery_like_count(posts, photo_id, 1)
             end)
             |> update(:modal_post, fn post ->
               if post && post.id == photo_id do
                 %{post | like_count: (post.like_count || 0) + 1}
               else
                 post
               end
             end)
             |> apply_gallery_filter()
             |> notify_success("Liked!")}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:modal_is_liked, true)
             |> update(:user_likes, &MapSet.put(&1, photo_id))}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like photos")}
    end
  end

  @impl true
  def handle_info({:new_gallery_post, post}, socket) do
    if socket.assigns.current_filter in ["discover", "trending"] do
      post_with_associations = Elektrine.Repo.preload(post, [:sender, sender: :profile])

      {:noreply,
       socket
       |> update(:gallery_posts, fn posts -> [post_with_associations | posts] end)
       |> apply_gallery_filter()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:post_liked, %{message_id: message_id, like_count: like_count}}, socket) do
    updated_posts =
      Enum.map(socket.assigns.gallery_posts, fn post ->
        if post.id == message_id do
          %{post | like_count: like_count}
        else
          post
        end
      end)

    {:noreply, socket |> assign(:gallery_posts, updated_posts) |> apply_gallery_filter()}
  end

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    updated_posts =
      Enum.map(socket.assigns.gallery_posts, fn post ->
        if post.id == message_id do
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }
        else
          post
        end
      end)

    updated_modal_post =
      case socket.assigns[:modal_post] do
        %{id: ^message_id} = post ->
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }

        post ->
          post
      end

    {:noreply,
     socket
     |> assign(:gallery_posts, updated_posts)
     |> assign(:modal_post, updated_modal_post)
     |> apply_gallery_filter()}
  end

  def handle_info(:load_gallery_data, socket) do
    user = socket.assigns[:current_user]
    gallery_posts = get_gallery_feed("discover", user)
    {user_likes, user_saved_posts} = load_gallery_engagement_state(user, gallery_posts)

    {user_gallery_stats, recent_uploads, top_upload, suggested_photographers, trending_tags} =
      if user do
        stats_task = Task.async(fn -> get_user_gallery_stats(user.id) end)
        highlights_task = Task.async(fn -> get_user_gallery_highlights(user.id) end)
        photographers_task = Task.async(fn -> get_suggested_photographers(user.id, limit: 5) end)

        tags_task =
          Task.async(fn ->
            Social.get_trending_hashtags(limit: 8)
            |> Enum.filter(fn hashtag ->
              String.contains?(hashtag.name, ["photo", "art", "design", "anime", "illustration"])
            end)
          end)

        stats = Task.await(stats_task, 5000)
        {recent_uploads, top_upload} = Task.await(highlights_task, 5000)

        photographers =
          if !stats || stats.photo_count == 0 do
            Task.await(photographers_task, 5000)
          else
            []
          end

        tags = Task.await(tags_task, 5000)
        {stats, recent_uploads, top_upload, photographers, tags}
      else
        tags =
          Social.get_trending_hashtags(limit: 8)
          |> Enum.filter(fn hashtag ->
            String.contains?(hashtag.name, ["photo", "art", "design", "anime", "illustration"])
          end)

        {nil, [], nil, [], tags}
      end

    {:noreply,
     socket
     |> assign(:gallery_posts, gallery_posts)
     |> assign(:filtered_posts, gallery_posts)
     |> assign(:user_likes, user_likes)
     |> assign(:user_saved_posts, user_saved_posts)
     |> assign(:user_gallery_stats, user_gallery_stats)
     |> assign(:recent_uploads, recent_uploads)
     |> assign(:top_upload, top_upload)
     |> assign(:suggested_photographers, suggested_photographers)
     |> assign(:trending_tags, trending_tags)
     |> assign(:loading_gallery, false)
     |> assign(:end_of_feed, length(gallery_posts) < @gallery_page_size)
     |> apply_gallery_filter()}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  defp error_to_string(:too_large) do
    "Image is too large (max 10MB)"
  end

  defp error_to_string(:not_accepted) do
    "Invalid file type. Please upload JPG, PNG, GIF, or WEBP"
  end

  defp error_to_string(:too_many_files) do
    "Only one image can be uploaded at a time"
  end

  defp error_to_string(_) do
    "Upload error"
  end

  defp get_gallery_feed(filter, user, opts \\ [])

  defp get_gallery_feed("discover", _user, opts) do
    import Ecto.Query
    before_timestamp = Keyword.get(opts, :before_timestamp)
    limit = Keyword.get(opts, :limit, @gallery_page_size)
    before_naive = normalize_to_naive(before_timestamp)

    local_query =
      from(m in Messaging.Message,
        where: m.post_type == "gallery" and m.visibility == "public" and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [sender: [:profile]]
      )

    local_query =
      if before_naive do
        from(m in local_query, where: m.inserted_at < ^before_naive)
      else
        local_query
      end

    local_posts = Elektrine.Repo.all(local_query)

    federated_query =
      from(m in Messaging.Message,
        where:
          m.federated == true and m.visibility in ["public", "unlisted"] and is_nil(m.deleted_at) and
            is_nil(m.reply_to_id) and fragment("array_length(?, 1)", m.media_urls) > 0,
        order_by: [desc: m.inserted_at],
        limit: ^(limit * 2),
        preload: [remote_actor: []]
      )

    federated_query =
      if before_naive do
        from(m in federated_query, where: m.inserted_at < ^before_naive)
      else
        federated_query
      end

    federated_posts = Elektrine.Repo.all(federated_query)

    (local_posts ++ federated_posts)
    |> Enum.sort_by(
      fn post ->
        case post.inserted_at do
          %DateTime{} = dt -> DateTime.to_unix(dt)
          %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
          _ -> 0
        end
      end,
      :desc
    )
    |> Enum.take(limit)
  end

  defp get_gallery_feed("following", user, opts) do
    if user do
      import Ecto.Query
      before_timestamp = Keyword.get(opts, :before_timestamp)
      limit = Keyword.get(opts, :limit, @gallery_page_size)
      before_naive = normalize_to_naive(before_timestamp)

      following_user_ids =
        from(f in Elektrine.Profiles.Follow,
          where: f.follower_id == ^user.id and not is_nil(f.followed_id),
          select: f.followed_id
        )
        |> Elektrine.Repo.all()

      following_user_ids = [user.id | following_user_ids] |> Enum.uniq()

      following_remote_actor_ids =
        from(f in Elektrine.Profiles.Follow,
          where:
            f.follower_id == ^user.id and not is_nil(f.remote_actor_id) and f.pending == false,
          select: f.remote_actor_id
        )
        |> Elektrine.Repo.all()

      local_query =
        from(m in Messaging.Message,
          where:
            m.post_type == "gallery" and is_nil(m.deleted_at) and
              m.sender_id in ^following_user_ids,
          order_by: [desc: m.inserted_at],
          limit: ^limit,
          preload: [sender: [:profile]]
        )

      local_query =
        if before_naive do
          from(m in local_query, where: m.inserted_at < ^before_naive)
        else
          local_query
        end

      local_posts = Elektrine.Repo.all(local_query)

      federated_posts =
        if Enum.empty?(following_remote_actor_ids) do
          []
        else
          federated_query =
            from(m in Messaging.Message,
              where:
                m.federated == true and m.remote_actor_id in ^following_remote_actor_ids and
                  is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
                  fragment("array_length(?, 1)", m.media_urls) > 0,
              order_by: [desc: m.inserted_at],
              limit: ^limit,
              preload: [remote_actor: []]
            )

          federated_query =
            if before_naive do
              from(m in federated_query, where: m.inserted_at < ^before_naive)
            else
              federated_query
            end

          Elektrine.Repo.all(federated_query)
        end

      (local_posts ++ federated_posts)
      |> Enum.sort_by(
        fn post ->
          case post.inserted_at do
            %DateTime{} = dt -> DateTime.to_unix(dt)
            %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
            _ -> 0
          end
        end,
        :desc
      )
      |> Enum.take(limit)
    else
      get_gallery_feed("discover", nil, opts)
    end
  end

  defp get_gallery_feed("liked", user, opts) do
    if user do
      import Ecto.Query
      before_timestamp = Keyword.get(opts, :before_timestamp)
      limit = Keyword.get(opts, :limit, @gallery_page_size)
      before_naive = normalize_to_naive(before_timestamp)

      query =
        from(m in Messaging.Message,
          join: l in Elektrine.Social.PostLike,
          on: l.message_id == m.id,
          where:
            l.user_id == ^user.id and
              is_nil(m.deleted_at) and
              is_nil(m.reply_to_id) and
              fragment("array_length(?, 1)", m.media_urls) > 0,
          order_by: [desc: l.created_at, desc: m.inserted_at],
          limit: ^limit,
          preload: [sender: [:profile], remote_actor: []]
        )

      query =
        if before_naive do
          from(m in query, where: m.inserted_at < ^before_naive)
        else
          query
        end

      Elektrine.Repo.all(query)
    else
      []
    end
  end

  defp get_gallery_feed("saved", user, opts) do
    if user do
      import Ecto.Query
      before_timestamp = Keyword.get(opts, :before_timestamp)
      limit = Keyword.get(opts, :limit, @gallery_page_size)
      before_naive = normalize_to_naive(before_timestamp)

      query =
        from(m in Messaging.Message,
          join: s in Elektrine.Social.SavedItem,
          on: s.message_id == m.id,
          where:
            s.user_id == ^user.id and
              is_nil(m.deleted_at) and
              is_nil(m.reply_to_id) and
              fragment("array_length(?, 1)", m.media_urls) > 0,
          order_by: [desc: s.inserted_at, desc: m.inserted_at],
          limit: ^limit,
          preload: [sender: [:profile], remote_actor: []]
        )

      query =
        if before_naive do
          from(m in query, where: m.inserted_at < ^before_naive)
        else
          query
        end

      Elektrine.Repo.all(query)
    else
      []
    end
  end

  defp get_gallery_feed("trending", _user, opts) do
    import Ecto.Query
    before_timestamp = Keyword.get(opts, :before_timestamp)
    limit = Keyword.get(opts, :limit, @gallery_page_size)
    before_naive = normalize_to_naive(before_timestamp)

    local_query =
      from(m in Messaging.Message,
        where: m.post_type == "gallery" and m.visibility == "public" and is_nil(m.deleted_at),
        order_by: [desc: m.like_count, desc: m.inserted_at],
        limit: ^limit,
        preload: [sender: [:profile]]
      )

    local_query =
      if before_naive do
        from(m in local_query, where: m.inserted_at < ^before_naive)
      else
        local_query
      end

    local_posts = Elektrine.Repo.all(local_query)

    federated_query =
      from(m in Messaging.Message,
        where:
          m.federated == true and m.visibility in ["public", "unlisted"] and is_nil(m.deleted_at) and
            is_nil(m.reply_to_id) and fragment("array_length(?, 1)", m.media_urls) > 0,
        order_by: [desc: m.like_count, desc: m.inserted_at],
        limit: ^limit,
        preload: [remote_actor: []]
      )

    federated_query =
      if before_naive do
        from(m in federated_query, where: m.inserted_at < ^before_naive)
      else
        federated_query
      end

    federated_posts = Elektrine.Repo.all(federated_query)

    (local_posts ++ federated_posts)
    |> Enum.sort_by(fn post ->
      timestamp =
        case post.inserted_at do
          %DateTime{} = dt -> DateTime.to_unix(dt)
          %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
          _ -> 0
        end

      {-(post.like_count || 0), -timestamp}
    end)
    |> Enum.take(limit)
  end

  defp get_gallery_feed(_, _user, opts) do
    get_gallery_feed("discover", nil, opts)
  end

  defp get_user_likes_set(user_id, posts) do
    user_id
    |> get_user_likes(posts)
    |> Enum.reduce(MapSet.new(), fn
      {message_id, true}, liked_ids -> MapSet.put(liked_ids, message_id)
      {_message_id, false}, liked_ids -> liked_ids
    end)
  end

  defp get_user_gallery_stats(user_id) do
    import Ecto.Query

    photo_count =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one()

    if photo_count > 0 do
      total_likes =
        from(m in Messaging.Message,
          where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
          select: sum(m.like_count)
        )
        |> Elektrine.Repo.one() || 0

      gallery_message_ids =
        from(m in Messaging.Message,
          where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
          select: m.id
        )
        |> Elektrine.Repo.all()

      total_views =
        if Enum.empty?(gallery_message_ids) do
          0
        else
          from(v in Social.PostView,
            where: v.message_id in ^gallery_message_ids,
            select: count(v.id)
          )
          |> Elektrine.Repo.one() || 0
        end

      streak = calculate_upload_streak(user_id)
      saved_count = Social.count_saved_posts(user_id)

      %{
        photo_count: photo_count,
        total_likes: total_likes,
        total_views: total_views,
        upload_streak: streak,
        saved_count: saved_count
      }
    else
      nil
    end
  end

  defp get_user_gallery_highlights(user_id) do
    import Ecto.Query

    recent_uploads =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: 3,
        preload: [sender: [:profile]]
      )
      |> Elektrine.Repo.all()

    top_upload =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        order_by: [desc: m.like_count, desc: m.inserted_at],
        limit: 1,
        preload: [sender: [:profile]]
      )
      |> Elektrine.Repo.one()

    {recent_uploads, top_upload}
  end

  defp calculate_upload_streak(user_id) do
    import Ecto.Query
    thirty_days_ago = Date.utc_today() |> Date.add(-30)

    upload_dates =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        select: fragment("DATE(?)", m.inserted_at),
        distinct: true,
        order_by: [desc: fragment("DATE(?)", m.inserted_at)]
      )
      |> Elektrine.Repo.all()
      |> Enum.filter(&(Date.compare(&1, thirty_days_ago) != :lt))

    count_consecutive_days(upload_dates, Date.utc_today(), 0)
  end

  defp count_consecutive_days([], _current_date, streak) do
    streak
  end

  defp count_consecutive_days([date | rest], current_date, streak) do
    if Date.compare(date, current_date) == :eq do
      count_consecutive_days(rest, Date.add(current_date, -1), streak + 1)
    else
      streak
    end
  end

  defp get_suggested_photographers(user_id, opts) do
    import Ecto.Query
    limit = Keyword.get(opts, :limit, 5)

    followed_ids =
      from(f in Elektrine.Profiles.Follow,
        where: f.follower_id == ^user_id,
        select: f.followed_id
      )
      |> Elektrine.Repo.all()

    from(m in Messaging.Message,
      join: u in Elektrine.Accounts.User,
      on: u.id == m.sender_id,
      where:
        m.post_type == "gallery" and is_nil(m.deleted_at) and m.sender_id != ^user_id and
          m.sender_id not in ^followed_ids,
      group_by: u.id,
      having: count(m.id) >= 3,
      order_by: [desc: count(m.id)],
      limit: ^limit,
      select: u
    )
    |> Elektrine.Repo.all()
    |> Elektrine.Repo.preload(:profile)
  end

  defp load_gallery_engagement_state(nil, _posts), do: {MapSet.new(), MapSet.new()}

  defp load_gallery_engagement_state(_user, []), do: {MapSet.new(), MapSet.new()}

  defp load_gallery_engagement_state(user, posts) do
    {get_user_likes_set(user.id, posts), get_user_saved_posts_set(user.id, posts)}
  end

  defp get_user_saved_posts_set(user_id, posts) do
    Social.list_user_saved_posts(user_id, Enum.map(posts, & &1.id))
  end

  defp apply_gallery_filter(socket) do
    filtered_posts =
      socket.assigns.gallery_posts
      |> filter_posts_by_category(socket.assigns.gallery_filter)
      |> filter_posts_by_software(socket.assigns.software_filter)
      |> filter_posts_by_search(socket.assigns.gallery_search)
      |> sort_gallery_posts(socket.assigns.gallery_sort)

    assign(socket, :filtered_posts, filtered_posts)
  end

  defp filter_posts_by_category(posts, "all") do
    posts
  end

  defp filter_posts_by_category(posts, category) do
    Enum.filter(posts, fn post -> post.category == category end)
  end

  defp filter_posts_by_search(posts, query) when query in [nil, ""], do: posts

  defp filter_posts_by_search(posts, query) do
    normalized_query = String.downcase(String.trim(query))

    Enum.filter(posts, fn post ->
      searchable_terms =
        [
          gallery_plain_text(post.title),
          gallery_plain_text(post.content),
          post.category,
          gallery_creator_name(post),
          gallery_creator_handle(post),
          gallery_source_label(post)
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)

      Enum.any?(searchable_terms, &String.contains?(&1, normalized_query))
    end)
  end

  defp normalize_to_naive(nil) do
    nil
  end

  defp normalize_to_naive(%NaiveDateTime{} = ndt) do
    ndt
  end

  defp normalize_to_naive(%DateTime{} = dt) do
    DateTime.to_naive(dt)
  end

  defp normalize_to_naive(_) do
    nil
  end

  defp sort_gallery_posts(posts, "popular") do
    Enum.sort_by(posts, &{-gallery_like_score(&1), -gallery_inserted_at_unix(&1)}, :asc)
  end

  defp sort_gallery_posts(posts, "discussed") do
    Enum.sort_by(
      posts,
      &{-(Map.get(&1, :reply_count, 0) || 0), -gallery_inserted_at_unix(&1)},
      :asc
    )
  end

  defp sort_gallery_posts(posts, _sort) do
    Enum.sort_by(posts, &gallery_inserted_at_unix/1, :desc)
  end

  defp filter_posts_by_software(posts, "all") do
    posts
  end

  defp filter_posts_by_software(posts, "local") do
    Enum.filter(posts, fn post -> !post.federated end)
  end

  defp filter_posts_by_software(posts, software) do
    domains =
      posts
      |> Enum.filter(
        &(&1.federated && &1.remote_actor &&
            !match?(%Ecto.Association.NotLoaded{}, &1.remote_actor))
      )
      |> Enum.map(& &1.remote_actor.domain)
      |> Enum.uniq()

    software_map = Elektrine.ActivityPub.Nodeinfo.get_software_batch(domains)

    Enum.filter(posts, fn post ->
      cond do
        !post.federated ->
          false

        post.remote_actor && !match?(%Ecto.Association.NotLoaded{}, post.remote_actor) ->
          instance_sw = Map.get(software_map, post.remote_actor.domain)
          software_matches?(instance_sw, software)

        true ->
          false
      end
    end)
  end

  defp software_matches?(nil, _) do
    false
  end

  defp software_matches?(instance_sw, filter) do
    filter = String.downcase(filter)

    case filter do
      "pleroma" -> instance_sw in ["pleroma", "akkoma"]
      "misskey" -> instance_sw in ["misskey", "calckey", "firefish", "iceshrimp", "sharkey"]
      "mastodon" -> instance_sw in ["mastodon", "hometown", "glitch"]
      "pixelfed" -> instance_sw == "pixelfed"
      _ -> instance_sw == filter
    end
  end

  defp update_gallery_like_count(posts, photo_id, delta) do
    Enum.map(posts, fn post ->
      if post.id == photo_id do
        %{post | like_count: max(0, (post.like_count || 0) + delta)}
      else
        post
      end
    end)
  end

  defp maybe_remove_from_collection_filter(socket, filter, photo_id) do
    if socket.assigns.current_filter == filter do
      update(socket, :gallery_posts, fn posts -> Enum.reject(posts, &(&1.id == photo_id)) end)
    else
      socket
    end
  end

  defp gallery_like_score(post), do: post.like_count || 0

  defp gallery_inserted_at_unix(post) do
    case post.inserted_at do
      %DateTime{} = dt -> DateTime.to_unix(dt)
      %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
      _ -> 0
    end
  end

  defp gallery_creator_name(post) do
    cond do
      post.sender && Ecto.assoc_loaded?(post.sender) ->
        actor_display_name_text(post.sender)

      post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        actor_display_name_text(post.remote_actor)

      true ->
        nil
    end
  end

  defp gallery_creator_handle(post) do
    cond do
      post.sender && Ecto.assoc_loaded?(post.sender) ->
        "@#{post.sender.handle || post.sender.username}"

      post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        "@#{post.remote_actor.username}@#{post.remote_actor.domain}"

      true ->
        nil
    end
  end

  defp gallery_creator_name_markup(post) do
    render_display_name_with_emojis(
      gallery_creator_name(post) || "Unknown creator",
      gallery_creator_domain(post)
    )
  end

  defp gallery_source_label(post) do
    cond do
      post.federated && post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        post.remote_actor.domain || "Fediverse"

      post.federated ->
        "Fediverse"

      true ->
        "Local"
    end
  end

  defp gallery_creator_domain(post) do
    if post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) do
      post.remote_actor.domain
    else
      nil
    end
  end

  defp gallery_display_title(post) do
    title = gallery_plain_text(post.title)
    content = gallery_plain_text(post.content)

    cond do
      Elektrine.Strings.present?(title) ->
        title

      Elektrine.Strings.present?(content) ->
        String.slice(content, 0, 70)

      true ->
        "#{String.capitalize(post.category || "gallery")} post"
    end
  end

  defp gallery_content_preview(post) do
    post.content
    |> gallery_plain_text()
    |> String.slice(0, 140)
  end

  defp gallery_plain_text(nil), do: ""
  defp gallery_plain_text(""), do: ""

  defp gallery_plain_text(text) when is_binary(text) do
    plain_text_content(text)
  end

  defp gallery_plain_text(_), do: ""

  defp gallery_primary_image(post) do
    post.media_urls
    |> List.first()
    |> case do
      nil -> nil
      url -> Elektrine.Uploads.attachment_url(url)
    end
  end

  defp gallery_image_urls(post) do
    Enum.map(post.media_urls || [], &Elektrine.Uploads.attachment_url/1)
  end

  defp gallery_image?(post) do
    case gallery_primary_image(post) do
      nil -> false
      url -> String.match?(url, ~r/\.(jpg|jpeg|png|gif|webp|avif|svg|bmp)(\?.*)?$/i)
    end
  end

  defp gallery_empty_state(assigns) do
    cond do
      assigns.gallery_search != "" ->
        {"No results for that search", "Try a different title, creator, source, or tag."}

      assigns.current_filter == "following" ->
        {"Nothing from people you follow yet",
         "Follow a few creators and their work will land here."}

      assigns.current_filter == "liked" ->
        {"No liked work yet", "Heart a few pieces and this view turns into a quick moodboard."}

      assigns.current_filter == "saved" ->
        {"Your saved collection is empty", "Bookmark standout work to keep a personal gallery."}

      assigns.current_filter == "trending" ->
        {"No trending work yet",
         "Fresh uploads will appear here once the gallery has some momentum."}

      true ->
        {"No gallery posts yet", "Upload your first image or broaden the filters."}
    end
  end

  defp format_gallery_count(value) when is_integer(value) and value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 1)}M"
  end

  defp format_gallery_count(value) when is_integer(value) and value >= 1_000 do
    "#{Float.round(value / 1_000, 1)}K"
  end

  defp format_gallery_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_gallery_count(_), do: "0"
end
