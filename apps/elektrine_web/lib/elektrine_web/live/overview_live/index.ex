defmodule ElektrineWeb.OverviewLive.Index do
  use ElektrineWeb, :live_view
  require Logger
  alias Elektrine.{Email, Friends, Messaging, Notifications, Profiles, Social, VPN}
  alias Elektrine.Social.Recommendations
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.TimelinePost
  import ElektrineWeb.Live.Helpers.PostStateHelpers
  @default_filter "all"
  @allowed_filters ~w(all my_posts timeline gallery discussions)
  @feed_load_timeout_ms 12_000
  @stats_load_timeout_ms 8000
  @dashboard_load_timeout_ms 10_000
  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]

    if user do
      locale = session["locale"] || (user && user.locale) || "en"
      Gettext.put_locale(ElektrineWeb.Gettext, locale)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "gallery:all")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussions:all")
        send(self(), :load_feed_data)
        send(self(), :load_stats_data)
        send(self(), :load_dashboard_data)
      end

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
       |> assign(:platform_stats, default_platform_stats())
       |> assign(:personal_stats, default_personal_stats())
       |> assign(:timezone, timezone)
       |> assign(:time_format, time_format)
       |> assign(:loading_feed, true)
       |> assign(:loading_stats, true)
       |> assign(:loading_dashboard, true)
       |> assign(:dashboard, default_dashboard())
       |> assign(:dashboard_last_refreshed_at, nil)
       |> assign(:data_loaded, false)
       |> assign(:show_image_modal, false)
       |> assign(:modal_image_url, nil)
       |> assign(:modal_images, [])
       |> assign(:modal_image_index, 0)
       |> assign(:modal_post, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Please sign in to view your personalized overview")
       |> push_navigate(to: ~p"/login")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = normalize_filter(params["filter"])

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
    {:noreply, push_patch(socket, to: ~p"/overview?filter=#{filter}")}
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
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
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    end
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
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
    else
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    end
  end

  def handle_event("navigate_to_post", %{"id" => id} = params, socket) do
    case parse_positive_int(id) do
      {:ok, post_id} ->
        post = Enum.find(socket.assigns.all_posts, &(&1.id == post_id))
        post_type = params["type"] || (post && post.post_type)

        cond do
          post && post.federated && post.activitypub_id ->
            {:noreply,
             push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(post.activitypub_id)}")}

          post_type == "post" ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{post_id}")}

          post_type == "gallery" ->
            path =
              if post && post.activitypub_id do
                "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
              else
                ~p"/remote/post/#{post_id}"
              end

            {:noreply, push_navigate(socket, to: path)}

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
    {:noreply, socket}
  end

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
    navigate_to_media_post(socket, :next)
  end

  def handle_event("prev_media_post", _params, socket) do
    navigate_to_media_post(socket, :prev)
  end

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
    liked_creators = params["liked_creators"] || []
    liked_local_creators = params["liked_local_creators"] || liked_creators

    session_context = %{
      liked_hashtags: params["liked_hashtags"] || [],
      liked_creators: liked_creators,
      liked_local_creators: liked_local_creators,
      liked_remote_creators: params["liked_remote_creators"] || [],
      viewed_posts: params["viewed_posts"] || [],
      engagement_rate: params["engagement_rate"] || 0.0
    }

    {:noreply, assign(socket, :session_context, session_context)}
  end

  def handle_event("", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp navigate_to_media_post(socket, direction) do
    modal_post = socket.assigns[:modal_post]
    posts = socket.assigns[:filtered_all_posts] || []

    if is_nil(modal_post) or Enum.empty?(posts) do
      {:noreply, socket}
    else
      media_posts =
        Enum.filter(posts, fn post ->
          media_urls = post.media_urls || []
          media_urls != []
        end)

      current_index = Enum.find_index(media_posts, fn post -> post.id == modal_post.id end)

      if is_nil(current_index) do
        {:noreply, socket}
      else
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

    {:noreply, socket |> update(:all_posts, update_fn) |> update(:filtered_all_posts, update_fn)}
  end

  def handle_info(:load_dashboard_data, socket) do
    user = socket.assigns.current_user

    case load_with_timeout(
           :dashboard_data,
           fn -> build_dashboard_data(user) end,
           @dashboard_load_timeout_ms
         ) do
      {:ok, dashboard} ->
        {:noreply,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:loading_dashboard, false)
         |> assign(:dashboard_last_refreshed_at, DateTime.utc_now())}

      {:error, _reason} ->
        {:noreply,
         socket |> assign(:dashboard, default_dashboard()) |> assign(:loading_dashboard, false)}
    end
  end

  def handle_info(:load_feed_data, socket) do
    user = socket.assigns.current_user
    session_context = socket.assigns[:session_context] || %{}

    personalized_result =
      load_with_timeout(
        :for_you_feed,
        fn ->
          Recommendations.get_for_you_feed(user.id, limit: 50, session_context: session_context)
          |> build_feed_state(user.id)
        end,
        @feed_load_timeout_ms
      )

    case personalized_result do
      {:ok, feed_data} ->
        {:noreply, assign_feed_data(socket, feed_data)}

      {:error, _reason} ->
        fallback_result =
          load_with_timeout(
            :public_feed_fallback,
            fn ->
              Social.get_public_timeline(user_id: user.id, limit: 50) |> build_feed_state(user.id)
            end,
            5000
          )

        case fallback_result do
          {:ok, feed_data} ->
            {:noreply,
             socket
             |> assign_feed_data(feed_data)
             |> put_flash(:info, "Showing recent posts while personalized ranking catches up.")}

          {:error, _fallback_reason} ->
            {:noreply,
             socket
             |> assign(:all_posts, [])
             |> assign(:filtered_all_posts, [])
             |> assign(:user_likes, %{})
             |> assign(:user_boosts, %{})
             |> assign(:user_follows, %{})
             |> assign(:pending_follows, %{})
             |> assign(:loading_feed, false)
             |> assign(:data_loaded, true)
             |> put_flash(:error, "Feed took too long to load. Please refresh to try again.")}
        end
    end
  end

  def handle_info(:load_stats_data, socket) do
    user = socket.assigns.current_user

    platform_stats =
      case load_with_timeout(
             :platform_stats,
             fn -> get_platform_stats() end,
             @stats_load_timeout_ms
           ) do
        {:ok, stats} -> stats
        {:error, _reason} -> default_platform_stats()
      end

    personal_stats =
      case load_with_timeout(
             :personal_stats,
             fn -> get_personal_stats(user.id) end,
             @stats_load_timeout_ms
           ) do
        {:ok, stats} -> stats
        {:error, _reason} -> default_personal_stats()
      end

    {:noreply,
     socket
     |> assign(:platform_stats, platform_stats)
     |> assign(:personal_stats, personal_stats)
     |> assign(:loading_stats, false)}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  defp get_user_likes_map(user_id, posts) do
    get_user_likes(user_id, posts)
  end

  defp get_user_boosts_map(user_id, posts) do
    get_user_boosts(user_id, posts)
  end

  defp default_dashboard do
    %{
      inbox_messages: [],
      inbox_unread_count: 0,
      chat_unread_count: 0,
      notifications_unread_count: 0,
      pending_friend_requests_count: 0,
      pending_follow_requests_count: 0,
      vpn_config_count: 0,
      tasks: [],
      alerts: [],
      quick_actions: quick_actions(),
      recent_activity: []
    }
  end

  defp quick_actions do
    [
      %{
        id: "compose_email",
        label: "Compose Email",
        detail: "Start a new message",
        href: ~p"/email/compose?return_to=overview",
        icon: "hero-pencil-square",
        tone: "primary"
      },
      %{
        id: "inbox",
        label: "Open Inbox",
        detail: "Review unread mail",
        href: ~p"/email?tab=inbox&filter=unread",
        icon: "hero-envelope",
        tone: "neutral"
      },
      %{
        id: "chat",
        label: "Open Chat",
        detail: "Jump into conversations",
        href: ~p"/chat",
        icon: "hero-chat-bubble-left-right",
        tone: "neutral"
      },
      %{
        id: "timeline",
        label: "Post to Timeline",
        detail: "Share an update",
        href: ~p"/timeline",
        icon: "hero-rectangle-stack",
        tone: "neutral"
      },
      %{
        id: "search",
        label: "Global Search",
        detail: "Find people, posts, and messages",
        href: ~p"/search",
        icon: "hero-magnifying-glass",
        tone: "neutral"
      },
      %{
        id: "vpn",
        label: "VPN",
        detail: "Manage your WireGuard configs",
        href: ~p"/vpn",
        icon: "hero-shield-check",
        tone: "neutral"
      }
    ]
  end

  defp build_dashboard_data(user) do
    mailbox = Email.get_user_mailbox(user.id)

    {inbox_messages, inbox_unread_count, reply_later_count} =
      if mailbox do
        {Email.list_inbox_messages(mailbox.id, 5, 0), Email.unread_inbox_count(mailbox.id),
         Email.unread_reply_later_count(mailbox.id)}
      else
        {[], 0, 0}
      end

    chat_unread_count = Messaging.get_unread_count(user.id)
    recent_conversations = Messaging.list_conversations(user.id, limit: 3)
    notifications_unread_count = Notifications.get_unread_count(user.id)
    recent_notifications = Notifications.list_notifications(user.id, limit: 8)
    pending_friend_requests = Friends.list_pending_requests(user.id)
    pending_follow_requests = Profiles.get_pending_follow_requests(user.id)
    vpn_configs = VPN.list_user_configs(user.id)
    recent_posts = Social.get_user_timeline_posts(user.id, limit: 3)
    pending_friend_requests_count = length(pending_friend_requests)
    pending_follow_requests_count = length(pending_follow_requests)
    vpn_config_count = length(vpn_configs)

    tasks =
      build_dashboard_tasks(
        inbox_unread_count,
        reply_later_count,
        chat_unread_count,
        pending_friend_requests_count,
        pending_follow_requests_count,
        vpn_config_count
      )

    alerts =
      build_dashboard_alerts(
        inbox_unread_count,
        notifications_unread_count,
        chat_unread_count,
        pending_follow_requests_count
      )

    %{
      inbox_messages: inbox_messages,
      inbox_unread_count: inbox_unread_count,
      chat_unread_count: chat_unread_count,
      notifications_unread_count: notifications_unread_count,
      pending_friend_requests_count: pending_friend_requests_count,
      pending_follow_requests_count: pending_follow_requests_count,
      vpn_config_count: vpn_config_count,
      tasks: tasks,
      alerts: alerts,
      quick_actions: quick_actions(),
      recent_activity:
        build_recent_activity(
          inbox_messages,
          recent_conversations,
          recent_posts,
          recent_notifications,
          vpn_configs
        )
    }
  end

  defp build_dashboard_tasks(
         inbox_unread_count,
         reply_later_count,
         chat_unread_count,
         pending_friend_requests_count,
         pending_follow_requests_count,
         vpn_config_count
       ) do
    [
      if inbox_unread_count > 0 do
        %{
          id: "review_inbox",
          title: "Review unread inbox",
          detail: "#{inbox_unread_count} message(s) waiting",
          href: ~p"/email?tab=inbox&filter=unread",
          icon: "hero-envelope",
          priority: "high"
        }
      end,
      if reply_later_count > 0 do
        %{
          id: "reply_later",
          title: "Handle boomerang reminders",
          detail: "#{reply_later_count} follow-up reminder(s)",
          href: ~p"/email?tab=inbox&filter=boomerang",
          icon: "hero-arrow-uturn-left",
          priority: "medium"
        }
      end,
      if pending_friend_requests_count > 0 do
        %{
          id: "friend_requests",
          title: "Respond to friend requests",
          detail: "#{pending_friend_requests_count} pending request(s)",
          href: ~p"/friends?tab=requests",
          icon: "hero-user-plus",
          priority: "medium"
        }
      end,
      if pending_follow_requests_count > 0 do
        %{
          id: "follow_requests",
          title: "Review fediverse follows",
          detail: "#{pending_follow_requests_count} remote request(s)",
          href: ~p"/friends?tab=requests",
          icon: "hero-globe-americas",
          priority: "high"
        }
      end,
      if chat_unread_count > 0 do
        %{
          id: "chat_unread",
          title: "Catch up on chat",
          detail: "#{chat_unread_count} unread chat message(s)",
          href: ~p"/chat",
          icon: "hero-chat-bubble-left-right",
          priority: "medium"
        }
      end,
      if vpn_config_count == 0 do
        %{
          id: "vpn_setup",
          title: "Create your first VPN config",
          detail: "Protect your traffic before browsing",
          href: ~p"/vpn",
          icon: "hero-shield-check",
          priority: "low"
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_dashboard_alerts(
         inbox_unread_count,
         notifications_unread_count,
         chat_unread_count,
         pending_follow_requests_count
       ) do
    [
      if pending_follow_requests_count > 0 do
        %{
          id: "fediverse_follow_requests",
          title: "Pending fediverse follow approvals",
          detail: "#{pending_follow_requests_count} request(s) are waiting",
          href: ~p"/friends?tab=requests",
          icon: "hero-globe-americas",
          level: "high"
        }
      end,
      if notifications_unread_count >= 15 do
        %{
          id: "notification_backlog",
          title: "Notification backlog building up",
          detail: "#{notifications_unread_count} unread notifications",
          href: ~p"/notifications",
          icon: "hero-bell-alert",
          level: "medium"
        }
      end,
      if inbox_unread_count >= 25 do
        %{
          id: "inbox_backlog",
          title: "Inbox backlog is growing",
          detail: "#{inbox_unread_count} unread inbox messages",
          href: ~p"/email?tab=inbox&filter=unread",
          icon: "hero-envelope",
          level: "medium"
        }
      end,
      if chat_unread_count >= 20 do
        %{
          id: "chat_backlog",
          title: "Chat backlog is growing",
          detail: "#{chat_unread_count} unread chat messages",
          href: ~p"/chat",
          icon: "hero-chat-bubble-left-right",
          level: "low"
        }
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_recent_activity(
         inbox_messages,
         recent_conversations,
         recent_posts,
         recent_notifications,
         vpn_configs
       ) do
    email_items =
      inbox_messages
      |> Enum.take(3)
      |> Enum.map(fn message ->
        %{
          id: "email-#{message.id}",
          app: "Email",
          title: inbox_subject(message),
          detail: "From #{inbox_sender(message.from)}",
          href: ~p"/email/view/#{message.hash || message.id}",
          icon: "hero-envelope",
          at: message.inserted_at
        }
      end)

    chat_items =
      recent_conversations
      |> Enum.take(3)
      |> Enum.map(fn conversation ->
        %{
          id: "chat-#{conversation.id}",
          app: "Chat",
          title: conversation_label(conversation),
          detail: String.capitalize(conversation.type || "conversation"),
          href: ~p"/chat/#{conversation.hash || conversation.id}",
          icon: "hero-chat-bubble-left-right",
          at: conversation.last_message_at || conversation.updated_at || conversation.inserted_at
        }
      end)

    social_items =
      recent_posts
      |> Enum.take(3)
      |> Enum.map(fn post ->
        %{
          id: "social-#{post.id}",
          app: "Social",
          title: social_post_title(post),
          detail: "Timeline update",
          href: ~p"/timeline/post/#{post.id}",
          icon: "hero-rectangle-stack",
          at: post.inserted_at
        }
      end)

    notification_items =
      recent_notifications
      |> Enum.take(3)
      |> Enum.map(fn notification ->
        %{
          id: "notification-#{notification.id}",
          app: notification_activity_app(notification),
          title: trim_or(notification.title, "Notification"),
          detail: notification_activity_detail(notification),
          href: normalize_internal_path(notification.url),
          icon: notification_activity_icon(notification),
          at: notification.inserted_at
        }
      end)

    vpn_items =
      case Enum.max_by(vpn_configs, &sort_datetime(&1.updated_at || &1.inserted_at), fn -> nil end) do
        nil ->
          []

        config ->
          [
            %{
              id: "vpn-#{config.id}",
              app: "VPN",
              title: "VPN profile ready",
              detail: trim_or(config.vpn_server && config.vpn_server.name, "WireGuard config"),
              href: ~p"/vpn",
              icon: "hero-shield-check",
              at: config.updated_at || config.inserted_at
            }
          ]
      end

    (email_items ++ chat_items ++ social_items ++ notification_items ++ vpn_items)
    |> Enum.sort_by(&sort_datetime(&1.at), :desc)
    |> Enum.take(10)
  end

  defp trim_or(value, fallback) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      fallback
    else
      value
    end
  end

  defp trim_or(_value, fallback) do
    fallback
  end

  defp inbox_subject(%{subject: subject}) when is_binary(subject) do
    subject |> trim_or("(No subject)") |> truncate_text(72)
  end

  defp inbox_subject(_) do
    "(No subject)"
  end

  defp inbox_sender(from) do
    from |> trim_or("Unknown sender") |> extract_sender_name() |> truncate_text(42)
  end

  defp extract_sender_name(from) when is_binary(from) do
    case Regex.run(~r/^(.+?)\s*<(.+)>$/, from) do
      [_, name, _email] -> name |> String.trim() |> String.trim("\"") |> trim_or(from)
      _ -> from
    end
  end

  defp extract_sender_name(from) do
    from
  end

  defp truncate_text(text, max_length) when is_binary(text) and max_length > 1 do
    if String.length(text) > max_length do
      if max_length <= 3 do
        String.slice(text, 0, max_length)
      else
        String.slice(text, 0, max_length - 3) <> "..."
      end
    else
      text
    end
  end

  defp truncate_text(_text, _max_length) do
    ""
  end

  defp conversation_label(conversation) do
    name = trim_or(conversation.name, "")

    cond do
      name != "" -> name
      conversation.type == "dm" -> "Direct message"
      true -> "Conversation ##{conversation.id}"
    end
  end

  defp social_post_title(post) do
    trim_or(post.title || post.content, "New social post") |> truncate_text(72)
  end

  defp notification_activity_app(notification) do
    case {notification.type, notification.source_type} do
      {"email_received", _} -> "Email"
      {_, "message"} -> "Chat"
      {_, "post"} -> "Social"
      {_, "discussion"} -> "Social"
      {"follow", _} -> "Social"
      {"mention", _} -> "Social"
      _ -> "Alerts"
    end
  end

  defp notification_activity_icon(notification) do
    case notification.type do
      "email_received" -> "hero-envelope"
      "new_message" -> "hero-chat-bubble-left-right"
      "reply" -> "hero-chat-bubble-left"
      "follow" -> "hero-user-plus"
      "mention" -> "hero-at-symbol"
      "like" -> "hero-heart"
      _ -> "hero-bell"
    end
  end

  defp notification_activity_detail(notification) do
    trim_or(notification.body, "Recent update") |> truncate_text(90)
  end

  defp normalize_internal_path(path) when is_binary(path) do
    path = String.trim(path)

    if String.starts_with?(path, "/") do
      path
    else
      ~p"/notifications"
    end
  end

  defp normalize_internal_path(_) do
    ~p"/notifications"
  end

  defp sort_datetime(%DateTime{} = datetime) do
    DateTime.to_unix(datetime)
  end

  defp sort_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC") |> DateTime.to_unix()
  end

  defp sort_datetime(_) do
    0
  end

  defp quick_action_button_class("primary") do
    "btn btn-sm btn-secondary"
  end

  defp quick_action_button_class(_tone) do
    "btn btn-sm btn-ghost border border-base-300"
  end

  defp task_priority_badge_class("high") do
    "badge badge-error badge-xs"
  end

  defp task_priority_badge_class("medium") do
    "badge badge-warning badge-xs"
  end

  defp task_priority_badge_class(_priority) do
    "badge badge-ghost badge-xs"
  end

  defp alert_level_badge_class("high") do
    "badge badge-error badge-xs"
  end

  defp alert_level_badge_class("medium") do
    "badge badge-warning badge-xs"
  end

  defp alert_level_badge_class(_level) do
    "badge badge-info badge-xs"
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

  defp filtered_posts(posts, _, _assigns) do
    posts
  end

  defp normalize_filter(filter) when is_binary(filter) and filter in @allowed_filters do
    filter
  end

  defp normalize_filter(_) do
    @default_filter
  end

  defp base_posts_for_filter("my_posts", %{current_user: user}) do
    get_user_own_posts(user.id)
  end

  defp base_posts_for_filter(_filter, %{all_posts: posts}) do
    posts
  end

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

  defp parse_positive_int(value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_positive_int(_) do
    :error
  end

  defp parse_non_negative_int(value, _default) when is_integer(value) and value >= 0 do
    value
  end

  defp parse_non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_int(_, default) do
    default
  end

  defp assign_feed_data(socket, feed_data) do
    posts =
      base_posts_for_filter(socket.assigns.filter, %{
        socket.assigns
        | all_posts: feed_data.all_posts
      })

    socket
    |> assign(:all_posts, feed_data.all_posts)
    |> assign(:filtered_all_posts, posts)
    |> assign(:user_likes, feed_data.user_likes)
    |> assign(:user_boosts, feed_data.user_boosts)
    |> assign(:user_follows, feed_data.user_follows)
    |> assign(:pending_follows, feed_data.pending_follows)
    |> assign(:loading_feed, false)
    |> assign(:data_loaded, true)
  end

  defp build_feed_state(all_posts, user_id) do
    user_likes = get_user_likes_map(user_id, all_posts)
    user_boosts = get_user_boosts_map(user_id, all_posts)
    user_follows = get_user_follows(user_id, all_posts)
    pending_follows = get_pending_follows(user_id, all_posts)

    %{
      all_posts: all_posts,
      user_likes: user_likes,
      user_boosts: user_boosts,
      user_follows: user_follows,
      pending_follows: pending_follows
    }
  end

  defp default_platform_stats do
    %{posts_today: 0, posts_this_week: 0, active_users: 0, top_post_today: nil, top_creators: []}
  end

  defp default_personal_stats do
    %{
      total_posts: 0,
      timeline_posts: 0,
      gallery_posts: 0,
      discussion_posts: 0,
      total_likes: 0,
      followers: 0,
      following: 0,
      top_post: nil
    }
  end

  defp load_with_timeout(key, loader, timeout_ms) when is_function(loader, 0) do
    task = Task.async(loader)

    try do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          Logger.warning("Overview loader exited (#{key}): #{inspect(reason)}")
          {:error, reason}

        nil ->
          Logger.warning("Overview loader timed out (#{key}) after #{timeout_ms}ms")
          {:error, :timeout}
      end
    catch
      :exit, reason ->
        Logger.warning("Overview loader crashed (#{key}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_platform_stats do
    import Ecto.Query
    today_start = NaiveDateTime.utc_now() |> NaiveDateTime.beginning_of_day()

    posts_today =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    week_start = NaiveDateTime.utc_now() |> NaiveDateTime.add(-7 * 24 * 60 * 60)

    posts_this_week =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^week_start and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

    active_users =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            is_nil(m.deleted_at),
        select: m.sender_id,
        distinct: true
      )
      |> Elektrine.Repo.all()
      |> length()

    top_post_today =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^today_start and
            m.visibility == "public" and is_nil(m.deleted_at),
        order_by: [desc: m.like_count],
        limit: 1,
        preload: [sender: [:profile]]
      )
      |> Elektrine.Repo.one()

    top_creators =
      from(m in Messaging.Message,
        where:
          m.post_type in ["post", "gallery", "discussion"] and m.inserted_at > ^week_start and
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

  defp get_personal_stats(user_id) do
    import Ecto.Query

    total_posts =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: count(m.id)
      )
      |> Elektrine.Repo.one() || 0

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

    total_likes =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
            is_nil(m.deleted_at),
        select: sum(m.like_count)
      )
      |> Elektrine.Repo.one() || 0

    followers = Elektrine.Profiles.get_follower_count(user_id)
    following = Elektrine.Profiles.get_following_count(user_id)

    top_post =
      from(m in Messaging.Message,
        where:
          m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
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

  defp get_user_own_posts(user_id) do
    import Ecto.Query

    from(m in Messaging.Message,
      where:
        m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 50,
      preload: [sender: [:profile], conversation: [], link_preview: [], hashtags: []]
    )
    |> Elektrine.Repo.all()
  end
end
