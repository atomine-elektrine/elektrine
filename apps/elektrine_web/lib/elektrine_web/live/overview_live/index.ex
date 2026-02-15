defmodule ElektrineWeb.OverviewLive.Index do
  use ElektrineWeb, :live_view

  alias Elektrine.{Social, Messaging}
  alias Elektrine.Social.Recommendations
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.TimelinePost
  import ElektrineWeb.Live.Helpers.PostStateHelpers

  @default_filter "all"
  @allowed_filters ~w(all my_posts timeline gallery discussions)

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]

    # Require authentication for personalized overview
    if !user do
      {:ok,
       socket
       |> put_flash(:error, "Please sign in to view your personalized overview")
       |> push_navigate(to: ~p"/login")}
    else
      # Set locale from session or user preference
      locale = session["locale"] || (user && user.locale) || "en"
      Gettext.put_locale(ElektrineWeb.Gettext, locale)

      if connected?(socket) do
        # Subscribe to all activity
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "gallery:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussions:all")

        # Trigger async data loading after mount
        send(self(), :load_feed_data)
        send(self(), :load_stats_data)
      end

      # Get user timezone and time format preference
      timezone = user.timezone || "Etc/UTC"
      time_format = user.time_format || "12"

      {:ok,
       socket
       |> assign(:page_title, "Overview")
       |> assign(:all_posts, [])
       |> assign(:filtered_all_posts, [])
       |> assign(:user_likes, %{})
       |> assign(:user_boosts, %{})
       |> assign(:user_follows, %{})
       |> assign(:pending_follows, %{})
       |> assign(:filter, @default_filter)
       |> assign(:online_users, [])
       |> assign(:user_statuses, %{})
       |> assign(:platform_stats, %{
         posts_today: 0,
         posts_this_week: 0,
         active_users: 0,
         top_post_today: nil,
         top_creators: []
       })
       |> assign(:personal_stats, %{
         total_posts: 0,
         timeline_posts: 0,
         gallery_posts: 0,
         discussion_posts: 0,
         total_likes: 0,
         followers: 0,
         following: 0,
         top_post: nil
       })
       |> assign(:timezone, timezone)
       |> assign(:time_format, time_format)
       |> assign(:loading_feed, true)
       |> assign(:loading_stats, true)
       |> assign(:data_loaded, false)
       |> assign(:show_image_modal, false)
       |> assign(:modal_image_url, nil)
       |> assign(:modal_images, [])
       |> assign(:modal_image_index, 0)
       |> assign(:modal_post, nil)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Read filter from URL params
    filter = normalize_filter(params["filter"])

    # If data is already loaded, update filtered posts immediately
    # Otherwise, just set the filter (data will be loaded async)
    socket =
      if socket.assigns.data_loaded do
        socket
        |> assign(:filter, filter)
        |> assign(:filtered_all_posts, base_posts_for_filter(filter, socket.assigns))
      else
        assign(socket, :filter, filter)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = normalize_filter(filter)
    # Use push_patch to update URL so browser back button works
    {:noreply, push_patch(socket, to: ~p"/overview?filter=#{filter}")}
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          user_id = socket.assigns.current_user.id
          currently_liked = Map.get(socket.assigns.user_likes, message_id, false)

          update_likes_fn = fn posts ->
            Enum.map(posts, fn post ->
              if post.id == message_id do
                if currently_liked do
                  %{post | like_count: max(0, (post.like_count || 0) - 1)}
                else
                  %{post | like_count: (post.like_count || 0) + 1}
                end
              else
                post
              end
            end)
          end

          if currently_liked do
            case Social.unlike_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_likes, &Map.put(&1, message_id, false))
                 |> update(:all_posts, update_likes_fn)
                 |> update(:filtered_all_posts, update_likes_fn)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to unlike post")}
            end
          else
            case Social.like_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_likes, &Map.put(&1, message_id, true))
                 |> update(:all_posts, update_likes_fn)
                 |> update(:filtered_all_posts, update_likes_fn)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to like post")}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    end
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if !socket.assigns[:current_user] do
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          user_id = socket.assigns.current_user.id
          currently_boosted = Map.get(socket.assigns.user_boosts, message_id, false)

          update_boosts_fn = fn posts ->
            Enum.map(posts, fn post ->
              if post.id == message_id do
                if currently_boosted do
                  %{post | share_count: max(0, (post.share_count || 0) - 1)}
                else
                  %{post | share_count: (post.share_count || 0) + 1}
                end
              else
                post
              end
            end)
          end

          if currently_boosted do
            case Social.unboost_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_boosts, &Map.put(&1, message_id, false))
                 |> update(:all_posts, update_boosts_fn)
                 |> update(:filtered_all_posts, update_boosts_fn)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to unboost post")}
            end
          else
            case Social.boost_post(user_id, message_id) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_boosts, &Map.put(&1, message_id, true))
                 |> update(:all_posts, update_boosts_fn)
                 |> update(:filtered_all_posts, update_boosts_fn)}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to boost post")}
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid post id")}
      end
    end
  end

  def handle_event("navigate_to_post", %{"id" => id} = params, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == post_id))
        post_type = params["type"] || (post && post.post_type)

        cond do
          # Federated post - navigate to remote post view
          post && post.federated && post.activitypub_id ->
            {:noreply,
             push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(post.activitypub_id)}")}

          # Local timeline post
          post_type == "post" ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}

          # Gallery post - use remote post page with activitypub_id if available
          post_type == "gallery" ->
            path =
              if post && post.activitypub_id do
                "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
              else
                ~p"/remote/post/#{post_id}"
              end

            {:noreply, push_navigate(socket, to: path)}

          # Discussion post
          post_type == "discussion" && post ->
            conversation =
              if Ecto.assoc_loaded?(post.conversation) do
                post.conversation
              else
                Elektrine.Repo.get(Messaging.Conversation, post.conversation_id)
              end

            if conversation do
              {:noreply,
               push_navigate(socket, to: ~p"/communities/#{conversation.name}/post/#{post_id}")}
            else
              {:noreply, socket}
            end

          # Fallback - default to timeline post
          true ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/#{handle}")}
  end

  def handle_event("navigate_to_gallery_post", %{"id" => _id, "url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{url}")}
  end

  def handle_event("navigate_to_gallery_post", %{"id" => id}, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} -> {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("navigate_to_remote_post", %{"id" => _id, "url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{url}")}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id}, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} -> {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    # Navigate to the post page to reply
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post && post.federated && post.activitypub_id do
          {:noreply,
           push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(post.activitypub_id)}")}
        else
          {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message_id}")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("stop_propagation", _params, socket) do
    # Prevents event from bubbling up to card click
    {:noreply, socket}
  end

  # Image Modal Events
  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    with {:ok, decoded_images} <- Jason.decode(images_json),
         true <- is_list(decoded_images) and decoded_images != [] do
      images = Enum.filter(decoded_images, &is_binary/1)
      index_int = parse_non_negative_int(index, 0) |> min(max(length(images) - 1, 0))
      url = params["url"] || Enum.at(images, index_int, List.first(images))

      modal_post =
        case params["post_id"] do
          nil ->
            nil

          post_id ->
            case parse_positive_int(post_id) do
              {:ok, id} ->
                Enum.find(socket.assigns.filtered_all_posts, fn post -> post.id == id end)

              :error ->
                nil
            end
        end

      {:noreply,
       socket
       |> assign(:show_image_modal, true)
       |> assign(:modal_image_url, url)
       |> assign(:modal_images, images)
       |> assign(:modal_image_index, index_int)
       |> assign(:modal_post, modal_post)}
    else
      _ -> {:noreply, socket}
    end
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

  # Navigate to next/previous post with media (scroll up/down in modal)
  def handle_event("next_media_post", _params, socket) do
    navigate_to_media_post(socket, :next)
  end

  def handle_event("prev_media_post", _params, socket) do
    navigate_to_media_post(socket, :prev)
  end

  # Additional handlers for timeline_post component
  def handle_event("view_post", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post do
          path =
            case post.post_type do
              "gallery" ->
                if post.activitypub_id do
                  "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
                else
                  ~p"/remote/post/#{message_id}"
                end

              _ ->
                ~p"/timeline/post/#{message_id}"
            end

          {:noreply, push_navigate(socket, to: path)}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_post_link", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == message_id))

        if post do
          path =
            case post.post_type do
              "discussion" ->
                "/posts/#{message_id}"

              "gallery" ->
                if post.activitypub_id do
                  "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
                else
                  "/remote/post/#{message_id}"
                end

              _ ->
                "/timeline/post/#{message_id}"
            end

          url = ElektrineWeb.Endpoint.url() <> path
          {:noreply, push_event(socket, "copy_to_clipboard", %{text: url})}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_post", %{"message_id" => message_id}, socket) do
    user = socket.assigns.current_user

    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        case Messaging.get_message(message_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Post not found")}

          message ->
            if message.sender_id == user.id do
              case Messaging.Messages.delete_message(message_id, user.id) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> update(:all_posts, fn posts ->
                     Enum.reject(posts, &(&1.id == message_id))
                   end)
                   |> update(:filtered_all_posts, fn posts ->
                     Enum.reject(posts, &(&1.id == message_id))
                   end)
                   |> put_flash(:info, "Post deleted")}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Failed to delete post")}
              end
            else
              {:noreply, put_flash(socket, :error, "You can only delete your own posts")}
            end
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid post id")}
    end
  end

  def handle_event("navigate_to_embedded_post", %{"message_id" => message_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message_id}")}
  end

  def handle_event("open_external_link", %{"url" => url}, socket) do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("toggle_follow", %{"user_id" => user_id}, socket) do
    case parse_positive_int(user_id) do
      {:ok, user_id} ->
        current_user = socket.assigns.current_user
        is_following = Map.get(socket.assigns.user_follows, {:local, user_id}, false)

        if is_following do
          case Social.unfollow_user(current_user.id, user_id) do
            {:ok, _} ->
              {:noreply, update(socket, :user_follows, &Map.put(&1, {:local, user_id}, false))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unfollow user")}
          end
        else
          case Social.follow_user(current_user.id, user_id) do
            {:ok, _} ->
              {:noreply, update(socket, :user_follows, &Map.put(&1, {:local, user_id}, true))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to follow user")}
          end
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_follow_remote", %{"actor_id" => actor_id}, socket) do
    case parse_positive_int(actor_id) do
      {:ok, actor_id} ->
        current_user = socket.assigns.current_user
        is_following = Map.get(socket.assigns.user_follows, {:remote, actor_id}, false)

        if is_following do
          case Elektrine.Profiles.unfollow_remote_actor(current_user.id, actor_id) do
            {:ok, _} ->
              {:noreply, update(socket, :user_follows, &Map.put(&1, {:remote, actor_id}, false))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unfollow")}
          end
        else
          case Elektrine.Profiles.follow_remote_actor(current_user.id, actor_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, true))
               |> update(:pending_follows, &Map.put(&1, {:remote, actor_id}, true))}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to follow")}
          end
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("report_post", _params, socket) do
    {:noreply, put_flash(socket, :info, "Report feature coming soon")}
  end

  def handle_event("delete_post_admin", _params, socket) do
    {:noreply, put_flash(socket, :error, "Admin actions not available here")}
  end

  # Dwell time tracking events
  def handle_event("record_dwell_time", params, socket) do
    user = socket.assigns[:current_user]

    if user do
      post_id = params["post_id"]

      if post_id do
        attrs = %{
          dwell_time_ms: params["dwell_time_ms"],
          scroll_depth: params["scroll_depth"],
          expanded: params["expanded"] || false,
          source: params["source"] || "overview"
        }

        Elektrine.Social.Recommendations.record_view_with_dwell(user.id, post_id, attrs)
      end
    end

    {:noreply, socket}
  end

  def handle_event("record_dwell_times", %{"views" => views}, socket) do
    user = socket.assigns[:current_user]

    if user do
      Enum.each(views, fn view ->
        post_id = view["post_id"]

        if post_id do
          attrs = %{
            dwell_time_ms: view["dwell_time_ms"],
            scroll_depth: view["scroll_depth"],
            expanded: view["expanded"] || false,
            source: view["source"] || "overview"
          }

          Elektrine.Social.Recommendations.record_view_with_dwell(user.id, post_id, attrs)
        end
      end)
    end

    {:noreply, socket}
  end

  def handle_event("record_dismissal", params, socket) do
    user = socket.assigns[:current_user]

    if user do
      post_id = params["post_id"]
      type = params["type"]
      dwell_time_ms = params["dwell_time_ms"]

      if post_id && type do
        Elektrine.Social.Recommendations.record_dismissal(user.id, post_id, type, dwell_time_ms)
      end
    end

    {:noreply, socket}
  end

  def handle_event("update_session_context", params, socket) do
    # Store session context in socket assigns for use in next feed refresh
    session_context = %{
      liked_hashtags: params["liked_hashtags"] || [],
      liked_creators: params["liked_creators"] || [],
      viewed_posts: params["viewed_posts"] || [],
      engagement_rate: params["engagement_rate"] || 0.0
    }

    {:noreply, assign(socket, :session_context, session_context)}
  end

  # Catch-all for empty/unknown events (some clicks in timeline_post trigger empty events)
  def handle_event("", _params, socket), do: {:noreply, socket}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp navigate_to_media_post(socket, direction) do
    modal_post = socket.assigns[:modal_post]
    posts = socket.assigns[:filtered_all_posts] || []

    if is_nil(modal_post) or Enum.empty?(posts) do
      {:noreply, socket}
    else
      # Find posts with media
      media_posts =
        Enum.filter(posts, fn post ->
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

  @impl true
  def handle_info({:new_timeline_post, post}, socket) do
    post_with_associations = Elektrine.Repo.preload(post, sender: [:profile])
    {:noreply, prepend_new_post(socket, post_with_associations)}
  end

  def handle_info({:new_gallery_post, post}, socket) do
    post_with_associations = Elektrine.Repo.preload(post, sender: [:profile])
    {:noreply, prepend_new_post(socket, post_with_associations)}
  end

  def handle_info({:new_discussion_post, post}, socket) do
    post_with_associations = Elektrine.Repo.preload(post, sender: [:profile], conversation: [])
    {:noreply, prepend_new_post(socket, post_with_associations)}
  end

  def handle_info({:post_liked, %{message_id: message_id, like_count: like_count}}, socket) do
    update_fn = fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id do
          %{post | like_count: like_count}
        else
          post
        end
      end)
    end

    {:noreply,
     socket
     |> update(:all_posts, update_fn)
     |> update(:filtered_all_posts, update_fn)}
  end

  # Async data loading handlers
  def handle_info(:load_feed_data, socket) do
    user = socket.assigns.current_user

    # Get personalized recommendation feed (For You algorithm)
    session_context = socket.assigns[:session_context] || %{}

    all_posts =
      Recommendations.get_for_you_feed(user.id, limit: 50, session_context: session_context)

    # Get user likes and boosts as maps for timeline_post component
    user_likes = get_user_likes_map(user.id, all_posts)
    user_boosts = get_user_boosts_map(user.id, all_posts)

    # Get user follows
    user_follows = get_user_follows(user.id, all_posts)
    pending_follows = get_pending_follows(user.id, all_posts)

    # Apply filter based on current selection
    posts = base_posts_for_filter(socket.assigns.filter, %{socket.assigns | all_posts: all_posts})

    {:noreply,
     socket
     |> assign(:all_posts, all_posts)
     |> assign(:filtered_all_posts, posts)
     |> assign(:user_likes, user_likes)
     |> assign(:user_boosts, user_boosts)
     |> assign(:user_follows, user_follows)
     |> assign(:pending_follows, pending_follows)
     |> assign(:loading_feed, false)
     |> assign(:data_loaded, true)}
  end

  def handle_info(:load_stats_data, socket) do
    user = socket.assigns.current_user

    # Load stats in parallel using Task.async
    platform_task = Task.async(fn -> get_platform_stats() end)
    personal_task = Task.async(fn -> get_personal_stats(user.id) end)

    platform_stats = Task.await(platform_task, 10_000)
    personal_stats = Task.await(personal_task, 10_000)

    {:noreply,
     socket
     |> assign(:platform_stats, platform_stats)
     |> assign(:personal_stats, personal_stats)
     |> assign(:loading_stats, false)}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  # Helper functions
  # Get user likes as a map for timeline_post component
  defp get_user_likes_map(user_id, posts) do
    get_user_likes(user_id, posts)
  end

  # Get user boosts as a map for timeline_post component
  defp get_user_boosts_map(user_id, posts) do
    get_user_boosts(user_id, posts)
  end

  defp filtered_posts(posts, "timeline", _assigns) do
    Enum.filter(posts, fn post -> post.post_type == "post" end)
  end

  defp filtered_posts(posts, "gallery", _assigns) do
    Enum.filter(posts, fn post -> post.post_type == "gallery" end)
  end

  defp filtered_posts(posts, "discussions", _assigns) do
    Enum.filter(posts, fn post -> post.post_type == "discussion" end)
  end

  defp filtered_posts(posts, "my_posts", %{current_user: user}) do
    Enum.filter(posts, fn post -> post.sender_id == user.id end)
  end

  defp filtered_posts(posts, _, _assigns), do: posts

  defp normalize_filter(filter) when is_binary(filter) and filter in @allowed_filters, do: filter
  defp normalize_filter(_), do: @default_filter

  defp base_posts_for_filter("my_posts", %{current_user: user}) do
    get_user_own_posts(user.id)
  end

  defp base_posts_for_filter(_filter, %{all_posts: posts}), do: posts

  defp prepend_new_post(socket, post) do
    socket = update(socket, :all_posts, fn posts -> [post | posts] end)

    case socket.assigns.filter do
      "my_posts" ->
        if post.sender_id == socket.assigns.current_user.id do
          update(socket, :filtered_all_posts, fn posts -> [post | posts] end)
        else
          socket
        end

      _ ->
        update(socket, :filtered_all_posts, fn posts -> [post | posts] end)
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_positive_int(_), do: :error

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_, default), do: default

  # Get platform-wide statistics
  defp get_platform_stats do
    import Ecto.Query

    # Posts created today
    today_start = NaiveDateTime.utc_now() |> NaiveDateTime.beginning_of_day()

    posts_today =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and
            m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    # Posts this week
    week_start = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 24 * 60 * 60)

    posts_this_week =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and
            m.inserted_at > ^week_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    # Active users (posted in last 24 hours)
    active_users =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and
            m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: m.sender_id,
        distinct: true
      )
      |> Elektrine.Repo.all()
      |> length()

    # Most liked post today
    top_post_today =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and
            m.inserted_at > ^today_start and
            m.visibility == "public" and
            is_nil(m.deleted_at),
        order_by: [desc: m.like_count],
        limit: 1,
        preload: [sender: [:profile]]
      )
      |> Elektrine.Repo.one()

    # Top creators this week (by post count)
    top_creators =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and
            m.inserted_at > ^week_start and
            is_nil(m.deleted_at),
        group_by: m.sender_id,
        order_by: [desc: count(m.id)],
        limit: 5,
        select: m.sender_id
      )
      |> Elektrine.Repo.all()
      |> Enum.map(&Elektrine.Repo.get(Elektrine.Accounts.User, &1))
      |> Enum.reject(&is_nil/1)
      |> Elektrine.Repo.preload(:profile)

    %{
      posts_today: posts_today,
      posts_this_week: posts_this_week,
      active_users: active_users,
      top_post_today: top_post_today,
      top_creators: top_creators
    }
  end

  # Get personal user statistics
  defp get_personal_stats(user_id) do
    import Ecto.Query

    # Total posts across all types
    total_posts =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and
            m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    # Posts by type
    timeline_posts =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "post" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    gallery_posts =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "gallery" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    discussion_posts =
      from(m in Messaging.Message,
        where: m.sender_id == ^user_id and m.post_type == "discussion" and is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    # Total likes received
    total_likes =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and
            m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: sum(m.like_count)
      )
      |> Elektrine.Repo.one() || 0

    # Follower/following counts
    followers = Elektrine.Profiles.get_follower_count(user_id)
    following = Elektrine.Profiles.get_following_count(user_id)

    # Most liked post
    top_post =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and
            m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        order_by: [desc: m.like_count],
        limit: 1,
        select: %{id: m.id, title: m.title, likes: m.like_count, type: m.post_type}
      )
      |> Elektrine.Repo.one()

    %{
      total_posts: total_posts,
      timeline_posts: timeline_posts,
      gallery_posts: gallery_posts,
      discussion_posts: discussion_posts,
      total_likes: total_likes,
      followers: followers,
      following: following,
      top_post: top_post
    }
  end

  # Get user's own posts (for "My Posts" filter)
  defp get_user_own_posts(user_id) do
    import Ecto.Query

    from(m in Messaging.Message,
      where:
        m.sender_id == ^user_id and
          m.post_type in ["post", "gallery", "discussion"] and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 50,
      preload: [sender: [:profile], conversation: [], link_preview: [], hashtags: []]
    )
    |> Elektrine.Repo.all()
  end
end
