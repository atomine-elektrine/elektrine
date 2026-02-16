defmodule ElektrineWeb.TimelineLive.Index do
  use ElektrineWeb, :live_view

  require Logger

  alias Elektrine.Messaging
  alias Elektrine.Social
  alias Elektrine.RSS
  alias Elektrine.PubSubTopics
  alias Elektrine.Timeline.RateLimiter, as: TimelineRateLimiter
  alias ElektrineWeb.Components.Social.PostUtilities
  import ElektrineWeb.Components.Social.RSSItem
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.TimelinePost
  import ElektrineWeb.Components.Social.ReplyItem
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Live.Helpers.PostStateHelpers

  alias ElektrineWeb.TimelineLive.Router
  alias ElektrineWeb.TimelineLive.Operations.PostOperations

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) do
      if user do
        # Subscribe to timeline updates for authenticated users
        PubSubTopics.subscribe(PubSubTopics.user_timeline(user.id))
        PubSubTopics.subscribe(PubSubTopics.timeline_all())
      end

      # Subscribe to public timeline for all users
      PubSubTopics.subscribe(PubSubTopics.timeline_public())
    end

    # Initialize with empty data - everything loads async after connection
    socket =
      socket
      |> assign(:page_title, "Timeline")
      |> assign(:base_timeline_posts, [])
      |> assign(:special_view_cache, %{})
      |> assign(:timeline_posts, [])
      |> assign(:post_replies, %{})
      |> assign(:loading_remote_replies, MapSet.new())
      |> assign(:current_filter, if(user, do: "all", else: "public"))
      # all, mastodon, pixelfed, lemmy
      |> assign(:software_filter, "all")
      |> assign(:suggested_follows, [])
      |> assign(:trending_hashtags, Social.get_trending_hashtags(limit: 10, days_back: 7))
      |> assign(:new_post_content, "")
      |> assign(:new_post_title, nil)
      |> assign(:new_post_visibility, (user && user.default_post_visibility) || "public")
      |> assign(:new_post_content_warning, nil)
      |> assign(:new_post_sensitive, false)
      |> assign(:show_cw_input, false)
      |> assign(:show_post_composer, false)
      |> assign(:loading_more, false)
      |> assign(:no_more_posts, false)
      |> assign(:reply_to_post, nil)
      |> assign(:reply_to_post_recent_replies, [])
      |> assign(:reply_content, "")
      |> assign(:reply_to_reply_id, nil)
      |> assign(:timeline_filter, "all")
      |> assign(:filter_dropdown_open, false)
      |> assign(:filtered_posts, [])
      |> assign(:user_communities, [])
      |> assign(:available_conversations, [])
      |> assign(:user_likes, %{})
      |> assign(:user_downvotes, %{})
      |> assign(:post_interactions, %{})
      |> assign(:post_reactions, %{})
      |> assign(:user_follows, %{})
      |> assign(:pending_follows, %{})
      |> assign(:user_boosts, %{})
      |> assign(:user_saves, %{})
      |> assign(:show_report_modal, false)
      |> assign(:report_type, nil)
      |> assign(:report_id, nil)
      |> assign(:report_metadata, %{})
      |> assign(:remote_user_preview, nil)
      |> assign(:remote_user_loading, false)
      |> assign(:friends, [])
      |> assign(:friend_ids, [])
      |> assign(:show_image_upload_modal, false)
      |> assign(:pending_media_urls, [])
      |> assign(:pending_media_alt_texts, %{})
      |> assign(:show_image_modal, false)
      |> assign(:modal_image_url, nil)
      |> assign(:modal_images, [])
      |> assign(:modal_image_index, 0)
      |> assign(:modal_post, nil)
      |> assign(:queued_posts, [])
      |> assign(:recently_loaded_post_ids, [])
      |> assign(:recently_loaded_count, 0)
      |> assign(:lemmy_counts, %{})
      |> assign(:remote_poll_data, %{})
      |> assign(:remote_post_data, %{})
      |> assign(:rss_items, [])
      |> assign(:rss_saves, %{})
      |> assign(:remote_data_request_ref, nil)
      |> assign(:refresh_remote_counts_ref, nil)
      |> assign(:timeline_load_ref, nil)
      |> assign(:timeline_hydration_ref, nil)
      |> assign(:show_quote_modal, false)
      |> assign(:quote_target_post, nil)
      |> assign(:quote_content, "")
      # Search within timeline
      |> assign(:search_query, "")
      |> assign(:show_mobile_filters, false)
      # Draft support
      |> assign(:user_drafts, [])
      |> assign(:show_drafts_panel, false)
      |> assign(:editing_draft_id, nil)
      |> assign(:draft_auto_saved, false)
      |> assign(:draft_saving, false)
      # Loading state - start as true, set to false when data loads
      |> assign(:loading_timeline, true)

    # Allow image, video, and audio uploads for authenticated users
    socket =
      if user do
        allow_upload(socket, :timeline_attachments,
          accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav),
          max_entries: 4,
          # 50MB to accommodate video/audio files
          max_file_size: 50_000_000
        )
      else
        socket
      end

    # Load all data asynchronously after connection
    if connected?(socket) do
      send(self(), :load_timeline_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Read filter from URL params, default to "all" for authenticated, "public" otherwise
    filter = params["filter"] || if socket.assigns[:current_user], do: "all", else: "public"
    timeline_view = normalize_timeline_view(params["view"] || socket.assigns.timeline_filter)

    # On initial load (loading_timeline is true), just set the filter
    # The async :load_timeline_data handler will load the actual data
    cond do
      socket.assigns.loading_timeline ->
        {:noreply,
         socket
         |> assign(:current_filter, filter)
         |> assign(:timeline_filter, timeline_view)}

      # Main URL filter changed (all/following/local/etc.) - requires full data reload.
      filter != socket.assigns.current_filter ->
        {:noreply, queue_timeline_reload(socket, filter, timeline_view)}

      # Secondary timeline view changed (all/posts/replies/etc.) - apply locally.
      timeline_view != socket.assigns.timeline_filter ->
        updated_socket = assign(socket, :timeline_filter, timeline_view)

        cond do
          view_requires_data_reload?(timeline_view) ->
            {:noreply, queue_timeline_reload(updated_socket, filter, timeline_view)}

          view_requires_data_reload?(socket.assigns.timeline_filter) &&
              socket.assigns.base_timeline_posts != [] ->
            {:noreply,
             updated_socket
             |> assign(:timeline_posts, socket.assigns.base_timeline_posts)
             |> assign(:loading_timeline, false)
             |> apply_timeline_filter()}

          view_requires_data_reload?(socket.assigns.timeline_filter) ->
            {:noreply, queue_timeline_reload(updated_socket, filter, timeline_view)}

          true ->
            {:noreply,
             updated_socket |> assign(:loading_timeline, false) |> apply_timeline_filter()}
        end

      true ->
        {:noreply, socket}
    end
  end

  # Load data when filter changes after initial load
  defp load_data_for_filter(socket, filter) do
    case allow_timeline_read(socket, :filter_reload) do
      :ok ->
        do_load_data_for_filter(socket, filter)

      {:error, retry_after} ->
        {:noreply,
         socket
         |> assign(:loading_timeline, false)
         |> assign(:loading_more, false)
         |> put_flash(
           :error,
           "Timeline is being refreshed too quickly. Please retry in #{retry_after}s."
         )}
    end
  end

  defp do_load_data_for_filter(socket, filter) do
    user = socket.assigns[:current_user]
    timeline_view = socket.assigns.timeline_filter
    filter_changed = filter != socket.assigns.current_filter
    special_view_cache = socket.assigns[:special_view_cache] || %{}
    cache_key = {filter, timeline_view}

    cached_special_view = Map.get(special_view_cache, cache_key)

    posts =
      case cached_special_view do
        %{posts: cached_posts} -> cached_posts
        _ -> load_posts_for_filter(filter, user, timeline_view)
      end

    cached_post_replies =
      case cached_special_view do
        %{post_replies: cached_replies} when is_map(cached_replies) -> cached_replies
        _ -> %{}
      end

    # Keep a base timeline dataset for fast switching between non-special view modes.
    # For special views we preserve the existing base, unless the source filter changed.
    base_timeline_posts =
      cond do
        !view_requires_data_reload?(timeline_view) ->
          posts

        filter_changed ->
          load_posts_for_filter(filter, user, "all")

        socket.assigns.base_timeline_posts != [] ->
          socket.assigns.base_timeline_posts

        true ->
          load_posts_for_filter(filter, user, "all")
      end

    special_view_cache =
      Map.put(special_view_cache, cache_key, %{posts: posts, post_replies: cached_post_replies})

    # Load RSS items for relevant filters
    {rss_items, rss_saves} =
      cond do
        filter in ["rss", "all", "following"] && user ->
          items = RSS.get_timeline_items(user.id, limit: 20)
          item_ids = Enum.map(items, & &1.id)
          saves = Social.list_user_saved_rss_items(user.id, item_ids)
          saves_map = Enum.into(saves, %{}, fn id -> {id, true} end)
          {items, saves_map}

        filter == "saved" && user ->
          # Load saved RSS items for the saved filter
          items = Social.get_saved_rss_items(user.id, limit: 20)
          # All items in saved view are saved
          saves_map = Enum.into(items, %{}, fn item -> {item.id, true} end)
          {items, saves_map}

        true ->
          {[], %{}}
      end

    {:noreply,
     socket
     |> assign(:current_filter, filter)
     |> assign(:base_timeline_posts, base_timeline_posts)
     |> assign(:special_view_cache, special_view_cache)
     |> assign(:timeline_posts, posts)
     |> assign(:post_replies, cached_post_replies)
     |> assign(:loading_more, false)
     |> assign(:no_more_posts, false)
     |> assign(:recently_loaded_post_ids, [])
     |> assign(:recently_loaded_count, 0)
     |> assign(:lemmy_counts, socket.assigns[:lemmy_counts] || %{})
     |> assign(:remote_post_data, socket.assigns[:remote_post_data] || %{})
     |> assign(:remote_data_request_ref, nil)
     |> assign(:refresh_remote_counts_ref, nil)
     |> assign(:rss_items, rss_items)
     |> assign(:rss_saves, rss_saves)
     |> assign(:user_likes, %{})
     |> assign(:user_downvotes, %{})
     |> assign(:post_interactions, %{})
     |> assign(:post_reactions, %{})
     |> assign(:user_follows, %{})
     |> assign(:pending_follows, %{})
     |> assign(:user_boosts, %{})
     |> assign(:user_saves, %{})
     |> assign(:loading_timeline, false)
     |> apply_timeline_filter()
     |> maybe_schedule_background_refresh(posts)
     |> maybe_schedule_reply_ingestion(posts)
     |> maybe_queue_remote_data(posts)
     |> start_timeline_hydration(posts, filter, timeline_view, user)}
  end

  defp queue_timeline_reload(socket, filter, timeline_view) do
    load_ref = System.unique_integer([:positive, :monotonic])
    send(self(), {:load_view_data, load_ref, filter, timeline_view})

    socket
    |> assign(:timeline_load_ref, load_ref)
    |> assign(:timeline_filter, timeline_view)
    |> assign(:loading_timeline, Enum.empty?(socket.assigns.timeline_posts))
    |> assign(:loading_more, false)
    |> assign(:no_more_posts, false)
  end

  defp maybe_queue_remote_data(socket, posts) do
    posts_to_fetch = remote_posts_needing_fetch(posts, socket)

    if timeline_remote_enrichment_enabled?() && connected?(socket) && posts_to_fetch != [] do
      send(self(), {:load_remote_data, posts_to_fetch})
    end

    socket
  end

  defp remote_posts_needing_fetch(posts, socket) when is_list(posts) do
    lemmy_counts = socket.assigns[:lemmy_counts] || %{}
    remote_post_data = socket.assigns[:remote_post_data] || %{}
    post_replies = socket.assigns[:post_replies] || %{}

    posts
    |> Enum.filter(fn post ->
      post.federated && is_binary(post.activitypub_id)
    end)
    |> Enum.filter(fn post ->
      ap_id = post.activitypub_id
      lemmy_post? = PostUtilities.has_community_uri?(post)
      has_top_replies? = Map.get(post_replies, post.id, []) != []

      missing_lemmy_counts = lemmy_post? && !Map.has_key?(lemmy_counts, ap_id)
      missing_remote_post_data = !lemmy_post? && !Map.has_key?(remote_post_data, ap_id)
      missing_lemmy_top_comments = lemmy_post? && !has_top_replies?

      missing_lemmy_counts || missing_remote_post_data || missing_lemmy_top_comments
    end)
  end

  defp remote_posts_needing_fetch(_, _), do: []

  defp timeline_remote_enrichment_enabled? do
    Application.get_env(:elektrine, :timeline_remote_enrichment, false)
  end

  defp maybe_schedule_background_refresh(socket, posts) when is_list(posts) do
    message_ids =
      posts
      |> Enum.filter(&(&1.federated == true && is_integer(&1.id)))
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.take(20)

    if connected?(socket) && message_ids != [] do
      Task.start(fn ->
        Enum.each(message_ids, fn message_id ->
          _ = Elektrine.ActivityPub.RefreshCountsWorker.schedule_single_refresh(message_id)
        end)
      end)
    end

    socket
  end

  defp maybe_schedule_background_refresh(socket, _posts), do: socket

  defp maybe_schedule_reply_ingestion(socket, posts) when is_list(posts) do
    if connected?(socket) do
      existing_replies = socket.assigns[:post_replies] || %{}

      message_ids =
        posts
        |> Enum.filter(&(&1.federated == true && is_integer(&1.id) && (&1.reply_count || 0) > 0))
        |> Enum.reject(fn post ->
          Map.get(existing_replies, post.id, []) != []
        end)
        |> Enum.map(& &1.id)
        |> Enum.take(20)

      if message_ids != [] do
        Task.start(fn ->
          Enum.each(message_ids, fn message_id ->
            _ = Elektrine.ActivityPub.RepliesIngestWorker.enqueue(message_id)
          end)
        end)
      end
    end

    socket
  end

  defp maybe_schedule_reply_ingestion(socket, _posts), do: socket

  defp start_timeline_hydration(socket, posts, _filter, _timeline_view, _user)
       when not is_list(posts) or posts == [] do
    assign(socket, :timeline_hydration_ref, nil)
  end

  defp start_timeline_hydration(socket, posts, filter, timeline_view, user) do
    hydration_ref = System.unique_integer([:positive, :monotonic])
    parent = self()
    user_id = user && user.id

    Task.start(fn ->
      post_ids = Enum.map(posts, & &1.id)

      post_replies =
        if user_id do
          Social.get_direct_replies_for_posts(post_ids, user_id: user_id, limit_per_post: 3)
        else
          Social.get_direct_replies_for_posts(post_ids, limit_per_post: 3)
        end

      all_messages = posts ++ List.flatten(Map.values(post_replies))

      hydrated_state = %{
        post_replies: post_replies,
        post_reactions: get_post_reactions(posts),
        user_likes: if(user_id, do: get_user_likes(user_id, all_messages), else: %{}),
        user_follows: if(user_id, do: get_user_follows(user_id, all_messages), else: %{}),
        pending_follows: if(user_id, do: get_pending_follows(user_id, all_messages), else: %{}),
        user_boosts: if(user_id, do: get_user_boosts(user_id, all_messages), else: %{}),
        user_saves: if(user_id, do: get_user_saves(user_id, all_messages), else: %{})
      }

      send(parent, {:timeline_hydrated, hydration_ref, filter, timeline_view, hydrated_state})
    end)

    assign(socket, :timeline_hydration_ref, hydration_ref)
  end

  @impl true
  def handle_event(event_name, params, socket) do
    # Delegate ALL events to the router
    Router.route_event(event_name, params, socket)
  end

  # All event handlers now in operation modules via Router

  @impl true
  def handle_info({:load_view_data, load_ref, filter, timeline_view}, socket) do
    if load_ref == socket.assigns.timeline_load_ref do
      load_data_for_filter(assign(socket, :timeline_filter, timeline_view), filter)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:timeline_hydrated, hydration_ref, filter, timeline_view, hydrated_state},
        socket
      ) do
    cond do
      hydration_ref != socket.assigns.timeline_hydration_ref ->
        {:noreply, socket}

      filter != socket.assigns.current_filter || timeline_view != socket.assigns.timeline_filter ->
        {:noreply, socket}

      true ->
        cache_key = {filter, timeline_view}
        existing_cache = Map.get(socket.assigns.special_view_cache || %{}, cache_key, %{})

        special_view_cache =
          Map.put(
            socket.assigns.special_view_cache || %{},
            cache_key,
            Map.merge(existing_cache, %{
              posts: socket.assigns.timeline_posts,
              post_replies: Map.get(hydrated_state, :post_replies, %{})
            })
          )

        {:noreply,
         socket
         |> assign(:special_view_cache, special_view_cache)
         |> assign(:post_replies, Map.get(hydrated_state, :post_replies, %{}))
         |> assign(:post_reactions, Map.get(hydrated_state, :post_reactions, %{}))
         |> assign(:user_likes, Map.get(hydrated_state, :user_likes, %{}))
         |> assign(:user_follows, Map.get(hydrated_state, :user_follows, %{}))
         |> assign(:pending_follows, Map.get(hydrated_state, :pending_follows, %{}))
         |> assign(:user_boosts, Map.get(hydrated_state, :user_boosts, %{}))
         |> assign(:user_saves, Map.get(hydrated_state, :user_saves, %{}))}
    end
  end

  @impl true
  def handle_info(:load_timeline_data, socket) do
    user = socket.assigns[:current_user]
    filter = socket.assigns.current_filter
    {:noreply, loaded_socket} = load_data_for_filter(socket, filter)

    loaded_socket =
      loaded_socket
      |> assign(
        :user_drafts,
        if(user, do: Elektrine.Social.Drafts.list_drafts(user.id, limit: 20), else: [])
      )

    # Load secondary data (suggested follows, friends) for authenticated users
    if user do
      send(self(), :load_secondary_data)
    end

    {:noreply, loaded_socket}
  end

  @impl true
  def handle_info(:load_secondary_data, socket) do
    user = socket.assigns.current_user

    # Load suggested follows and friends list after initial data loads
    suggested_follows = Social.get_suggested_follows(user.id, limit: 5)
    friends = Elektrine.Friends.list_friends(user.id)
    friend_ids = Enum.map(friends, & &1.id)

    {:noreply,
     socket
     |> assign(:suggested_follows, suggested_follows)
     |> assign(:friends, friends)
     |> assign(:friend_ids, friend_ids)}
  end

  @impl true
  def handle_info(:load_more_timeline_posts, socket) do
    {:noreply, PostOperations.handle_load_more(socket)}
  end

  @impl true
  def handle_info({:load_remote_data, posts}, socket) do
    posts_to_fetch =
      if timeline_remote_enrichment_enabled?(),
        do: remote_posts_needing_fetch(posts, socket),
        else: []

    if posts_to_fetch == [] do
      {:noreply, socket}
    else
      request_ref = System.unique_integer([:positive, :monotonic])
      parent = self()

      Task.start(fn ->
        lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_posts_counts(posts_to_fetch)

        lemmy_top_comments =
          Elektrine.ActivityPub.LemmyApi.fetch_posts_top_comments(posts_to_fetch, 3)

        remote_post_data = Elektrine.ActivityPub.Helpers.fetch_remote_post_data(posts_to_fetch)

        send(
          parent,
          {:remote_data_loaded, request_ref, posts_to_fetch, lemmy_counts, remote_post_data,
           lemmy_top_comments}
        )
      end)

      {:noreply, assign(socket, :remote_data_request_ref, request_ref)}
    end
  end

  @impl true
  def handle_info(
        {:remote_data_loaded, request_ref, posts, lemmy_counts, remote_post_data,
         lemmy_top_comments},
        socket
      ) do
    if request_ref != socket.assigns.remote_data_request_ref do
      {:noreply, socket}
    else
      # Merge Lemmy top comments into post_replies (keyed by post.id not activitypub_id)
      updated_post_replies =
        posts
        |> Enum.reduce(socket.assigns.post_replies, fn post, acc ->
          case Map.get(lemmy_top_comments, post.activitypub_id) do
            nil ->
              acc

            [] ->
              acc

            comments ->
              if Map.get(acc, post.id, []) != [] do
                acc
              else
                Map.put(acc, post.id, materialize_lemmy_top_comments(post, comments))
              end
          end
        end)

      merged_lemmy_counts = Map.merge(socket.assigns.lemmy_counts || %{}, lemmy_counts)

      merged_remote_post_data =
        Map.merge(socket.assigns.remote_post_data || %{}, remote_post_data)

      {:noreply,
       socket
       |> assign(:lemmy_counts, merged_lemmy_counts)
       |> assign(:remote_post_data, merged_remote_post_data)
       |> assign(:post_replies, updated_post_replies)}
    end
  end

  @impl true
  def handle_info(:refresh_remote_counts, socket) do
    # Per-socket polling has been replaced with background refresh workers.
    {:noreply, maybe_schedule_background_refresh(socket, socket.assigns.timeline_posts)}
  end

  @impl true
  def handle_info(
        {:remote_counts_refreshed, _request_ref, _lemmy_counts, _remote_post_data},
        socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    # Update the post counts in real-time
    updated_posts =
      Enum.map(socket.assigns.timeline_posts, fn post ->
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

    {:noreply,
     socket
     |> assign(:timeline_posts, updated_posts)
     |> apply_timeline_filter()}
  end

  @impl true
  def handle_info({:remote_user_fetched, actor}, socket) do
    {:noreply, assign(socket, remote_user_preview: actor, remote_user_loading: false)}
  end

  def handle_info({:remote_user_fetch_failed, _handle}, socket) do
    {:noreply,
     socket
     |> assign(:remote_user_loading, false)
     |> put_flash(:error, "Could not find user")}
  end

  def handle_info({:follow_accepted, remote_actor_id}, socket) do
    # Move from pending to accepted
    updated_pending = Map.delete(socket.assigns.pending_follows, {:remote, remote_actor_id})
    updated_follows = Map.put(socket.assigns.user_follows, {:remote, remote_actor_id}, true)

    {:noreply,
     socket
     |> assign(:pending_follows, updated_pending)
     |> assign(:user_follows, updated_follows)}
  end

  @impl true
  def handle_info(:all_notifications_read, socket) do
    # Reset notification count when all notifications are read
    {:noreply, assign(socket, :notification_count, 0)}
  end

  @impl true
  def handle_info(:notification_updated, socket) do
    # Refresh notification count
    count =
      if socket.assigns.current_user do
        Elektrine.Notifications.get_unread_count(socket.assigns.current_user.id)
      else
        0
      end

    {:noreply, assign(socket, :notification_count, count)}
  end

  @impl true
  def handle_info({:notification_count_updated, count}, socket) do
    # Update notification count
    {:noreply, assign(socket, :notification_count, count)}
  end

  @impl true
  def handle_info({:new_timeline_post, post}, socket) do
    # Skip if this post is from the current user (already added optimistically)
    if socket.assigns[:current_user] && post.sender_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      preload_timeline_post_async(post, :timeline)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_post_preloaded, :timeline, post_with_associations}, socket) do
    # Update user_follows map for both local and federated posts
    updated_socket = socket

    # Check local follow status
    updated_socket =
      if post_with_associations.sender_id && socket.assigns[:current_user] do
        follow_key = {:local, post_with_associations.sender_id}

        if !Map.has_key?(socket.assigns.user_follows, follow_key) do
          is_following =
            Social.following?(socket.assigns.current_user.id, post_with_associations.sender_id)

          update(updated_socket, :user_follows, &Map.put(&1, follow_key, is_following))
        else
          updated_socket
        end
      else
        updated_socket
      end

    # Check remote follow status (for federated posts)
    updated_socket =
      if post_with_associations.remote_actor_id && socket.assigns[:current_user] do
        follow_key = {:remote, post_with_associations.remote_actor_id}

        if !Map.has_key?(socket.assigns.user_follows, follow_key) do
          is_following =
            Elektrine.Profiles.following_remote_actor?(
              socket.assigns.current_user.id,
              post_with_associations.remote_actor_id
            )

          update(updated_socket, :user_follows, &Map.put(&1, follow_key, is_following))
        else
          updated_socket
        end
      else
        updated_socket
      end

    # Queue the new post instead of adding directly to avoid disrupting reading
    # User can click "New posts" banner to load them
    # Skip if already in queue or timeline, or if it doesn't match current filter
    post_id = post_with_associations.id
    already_queued = Enum.any?(updated_socket.assigns.queued_posts, fn p -> p.id == post_id end)

    already_in_timeline =
      Enum.any?(updated_socket.assigns.timeline_posts, fn p -> p.id == post_id end)

    # Must match BOTH URL filter (current_filter) AND secondary filter (timeline_filter)
    matches_url_filter =
      post_matches_url_filter?(
        post_with_associations,
        updated_socket.assigns.current_filter,
        updated_socket
      )

    matches_timeline_filter =
      post_matches_filter?(
        post_with_associations,
        updated_socket.assigns.timeline_filter,
        updated_socket
      )

    matches_filter = matches_url_filter && matches_timeline_filter

    updated_socket =
      if already_queued || already_in_timeline || !matches_filter do
        updated_socket
      else
        update(updated_socket, :queued_posts, fn queued ->
          [post_with_associations | queued]
        end)
      end

    {:noreply, updated_socket}
  end

  @impl true
  def handle_info({:new_public_post, post}, socket) do
    # Skip if this post is from the current user (already added optimistically)
    if socket.assigns[:current_user] && post.sender_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      preload_timeline_post_async(post, :public)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_post_preloaded, :public, post_with_associations}, socket) do
    # Check if post matches current filter (both URL filter and timeline filter)
    matches_url_filter =
      post_matches_url_filter?(post_with_associations, socket.assigns.current_filter, socket)

    matches_timeline_filter =
      post_matches_filter?(post_with_associations, socket.assigns.timeline_filter, socket)

    if !matches_url_filter || !matches_timeline_filter do
      {:noreply, socket}
    else
      # Update user_follows map for both local and federated posts (only for logged-in users)
      updated_socket =
        if socket.assigns[:current_user] do
          # Check local follow status
          updated_socket =
            if post_with_associations.sender_id do
              follow_key = {:local, post_with_associations.sender_id}

              if !Map.has_key?(socket.assigns.user_follows, follow_key) do
                is_following =
                  Social.following?(
                    socket.assigns.current_user.id,
                    post_with_associations.sender_id
                  )

                update(socket, :user_follows, &Map.put(&1, follow_key, is_following))
              else
                socket
              end
            else
              socket
            end

          # Check remote follow status (for federated posts)
          if post_with_associations.remote_actor_id do
            follow_key = {:remote, post_with_associations.remote_actor_id}

            if !Map.has_key?(updated_socket.assigns.user_follows, follow_key) do
              is_following =
                Elektrine.Profiles.following_remote_actor?(
                  socket.assigns.current_user.id,
                  post_with_associations.remote_actor_id
                )

              update(updated_socket, :user_follows, &Map.put(&1, follow_key, is_following))
            else
              updated_socket
            end
          else
            updated_socket
          end
        else
          # Anonymous user - skip follow status checks
          socket
        end

      # Queue the new post instead of adding directly to avoid disrupting reading
      # Skip if already in queue or timeline
      post_id = post_with_associations.id

      already_queued =
        Enum.any?(updated_socket.assigns.queued_posts, fn p -> p.id == post_id end)

      already_in_timeline =
        Enum.any?(updated_socket.assigns.timeline_posts, fn p -> p.id == post_id end)

      if already_queued || already_in_timeline do
        {:noreply, updated_socket}
      else
        {:noreply,
         update(updated_socket, :queued_posts, fn queued ->
           [post_with_associations | queued]
         end)}
      end
    end
  end

  @impl true
  def handle_info({:post_liked, %{message_id: message_id, like_count: like_count}}, socket) do
    # Update like count in real-time for posts
    updated_posts =
      Enum.map(socket.assigns.timeline_posts, fn post ->
        if post.id == message_id do
          %{post | like_count: like_count}
        else
          post
        end
      end)

    # Also update replies if this is a reply
    updated_replies =
      Map.new(socket.assigns.post_replies, fn {post_id, replies} ->
        updated_reply_list =
          Enum.map(replies, fn reply ->
            if reply.id == message_id do
              %{reply | like_count: like_count}
            else
              reply
            end
          end)

        {post_id, updated_reply_list}
      end)

    {:noreply,
     socket
     |> assign(:timeline_posts, updated_posts)
     |> assign(:post_replies, updated_replies)
     |> apply_timeline_filter()}
  end

  @impl true
  def handle_info({:post_replies_loaded, post_id, replies}, socket) do
    updated_post_replies = Map.put(socket.assigns.post_replies, post_id, replies)
    loading_set = MapSet.delete(socket.assigns.loading_remote_replies, post_id)

    {:noreply,
     socket
     |> assign(:post_replies, updated_post_replies)
     |> assign(:loading_remote_replies, loading_set)}
  end

  @impl true
  def handle_info({:remote_replies_loaded, post_id, remote_replies}, socket) do
    # Convert remote ActivityPub replies to a format compatible with the reply display
    converted_replies = convert_remote_replies_to_display_format(remote_replies)

    # Merge into post_replies
    updated_post_replies = Map.put(socket.assigns.post_replies, post_id, converted_replies)

    # Clear loading state
    loading_set = MapSet.delete(socket.assigns.loading_remote_replies, post_id)

    {:noreply,
     socket
     |> assign(:post_replies, updated_post_replies)
     |> assign(:loading_remote_replies, loading_set)}
  end

  @impl true
  def handle_info({:reply_count_updated, message_id, new_count}, socket) do
    # Update the reply count for the specific post in the timeline
    updated_posts =
      Enum.map(socket.assigns.timeline_posts, fn post ->
        if post.id == message_id do
          %{post | reply_count: new_count}
        else
          post
        end
      end)

    {:noreply,
     socket
     |> assign(:timeline_posts, updated_posts)
     |> apply_timeline_filter()}
  end

  @impl true
  def handle_info({:load_followed_user_posts, user_id}, socket) do
    # Load posts from newly followed user in background
    current_user_id = socket.assigns.current_user.id

    new_user_posts =
      Social.get_user_timeline_posts(user_id, limit: 20, viewer_id: current_user_id)

    # Merge new posts into timeline and sort by date
    updated_posts = merge_and_sort_posts(socket.assigns.timeline_posts, new_user_posts)

    # Update user_likes for the new posts
    updated_user_likes =
      Map.merge(
        socket.assigns.user_likes,
        get_user_likes(current_user_id, new_user_posts)
      )

    {:noreply,
     socket
     |> assign(:timeline_posts, updated_posts)
     |> assign(:user_likes, updated_user_likes)
     |> apply_timeline_filter()}
  end

  @impl true
  def handle_info({:post_reaction_added, reaction}, socket) do
    # Update post_reactions for live updates
    message_id = reaction.message_id
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])

    # Add reaction if not already present (avoid duplicates from own action)
    already_present =
      Enum.any?(post_reactions, fn r ->
        r.id == reaction.id
      end)

    updated_reactions =
      if already_present do
        current_reactions
      else
        Map.put(current_reactions, message_id, [reaction | post_reactions])
      end

    {:noreply, assign(socket, :post_reactions, updated_reactions)}
  end

  @impl true
  def handle_info({:post_reaction_removed, reaction}, socket) do
    # Update post_reactions for live updates
    message_id = reaction.message_id
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])

    # Remove the reaction
    updated_post_reactions =
      Enum.reject(post_reactions, fn r ->
        r.emoji == reaction.emoji && r.user_id == reaction.user_id
      end)

    updated_reactions = Map.put(current_reactions, message_id, updated_post_reactions)

    {:noreply, assign(socket, :post_reactions, updated_reactions)}
  end

  @impl true
  def handle_info({:report_submitted, _reportable_type, _reportable_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_type, nil)
     |> assign(:report_id, nil)
     |> assign(:report_metadata, %{})
     |> put_flash(:info, "Report submitted. Thanks for helping keep the timeline safe.")}
  end

  @impl true
  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  # Helper to load posts based on filter
  defp load_posts_for_filter(filter, user, timeline_view) do
    case timeline_view do
      "replies" ->
        Social.get_federated_replies(limit: 20, user_id: user && user.id)

      "friends" ->
        if user do
          Social.get_friends_timeline(user.id, limit: 20)
        else
          []
        end

      "my_posts" ->
        if user do
          Social.get_user_timeline_posts(user.id, limit: 20, viewer_id: user.id)
        else
          []
        end

      "trusted" ->
        Social.get_trusted_timeline(limit: 20, user_id: user && user.id)

      _ ->
        case filter do
          "all" ->
            if user do
              Social.get_public_timeline(limit: 20, user_id: user.id)
            else
              Social.get_public_timeline(limit: 20)
            end

          "following" ->
            if user do
              Social.get_combined_feed(user.id, limit: 20)
            else
              Social.get_public_timeline(limit: 20)
            end

          "local" ->
            if user do
              Social.get_local_timeline(limit: 20, user_id: user.id)
            else
              Social.get_local_timeline(limit: 20)
            end

          "federated" ->
            Social.get_public_federated_posts(limit: 20)

          "saved" ->
            if user do
              Social.get_saved_posts(user.id, limit: 20)
            else
              []
            end

          "rss" ->
            []

          _ ->
            if user do
              Social.get_public_timeline(limit: 20, user_id: user.id)
            else
              Social.get_public_timeline(limit: 20)
            end
        end
    end
  end

  defp view_requires_data_reload?(timeline_view) do
    timeline_view in ["replies", "friends", "my_posts", "trusted"]
  end

  defp preload_timeline_post_async(post, source) do
    parent = self()

    Task.start(fn ->
      post_with_associations =
        Elektrine.Repo.preload(post, [
          :sender,
          :remote_actor,
          :link_preview,
          poll: [options: []]
        ])

      send(parent, {:new_post_preloaded, source, post_with_associations})
    end)
  end

  # Helper functions
  defp error_to_string(:too_large), do: "File is too large (max 50MB)"

  defp error_to_string(:not_accepted),
    do:
      "Invalid file type. Supported: Images (JPG, PNG, GIF, WEBP), Videos (MP4, WEBM, OGV, MOV), Audio (MP3, WAV)"

  defp error_to_string(:too_many_files), do: "Maximum 4 files allowed"
  defp error_to_string(_), do: "Upload error"

  defp merge_and_sort_posts(existing_posts, new_posts) do
    # Combine posts, remove duplicates by ID, and sort by date
    (existing_posts ++ new_posts)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
  end

  defp apply_timeline_filter(socket) do
    filtered_posts =
      case socket.assigns.timeline_filter do
        "posts" ->
          # Show posts (not replies), excluding Lemmy community posts
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            is_nil(Map.get(post, :reply_to_id)) &&
              !PostUtilities.has_community_uri?(post)
          end)

        "replies" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            # Check both reply_to_id (local) and inReplyTo in metadata (federated)
            !is_nil(Map.get(post, :reply_to_id)) ||
              !is_nil(get_in(post.media_metadata, ["inReplyTo"]))
          end)

        "media" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            media_urls = Map.get(post, :media_urls, [])
            has_media_urls = !Enum.empty?(media_urls)
            link_preview = Map.get(post, :link_preview)

            has_link_preview =
              match?(%Elektrine.Social.LinkPreview{}, link_preview) &&
                link_preview.status == "success" &&
                link_preview.image_url != nil

            has_media_urls || has_link_preview
          end)

        "friends" ->
          # Only show local posts from friends (federated posts don't have sender_id)
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.sender_id && post.sender_id in socket.assigns.friend_ids
          end)

        "my_posts" ->
          if socket.assigns.current_user do
            Enum.filter(socket.assigns.timeline_posts, fn post ->
              post.sender_id == socket.assigns.current_user.id
            end)
          else
            []
          end

        "trusted" ->
          # Filter to show local posts from TL2+ users only
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.federated != true &&
              (post.sender || %{}) |> Map.get(:trust_level, 0) >= 2
          end)

        "communities" ->
          # Filter to show only posts from federated communities (Lemmy)
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            PostUtilities.has_community_uri?(post)
          end)

        "federated" ->
          # Show only federated posts from the fediverse (all types)
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.federated == true
          end)

        "local" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            !is_nil(post.sender_id) && is_nil(post.remote_actor_id)
          end)

        _ ->
          socket.assigns.timeline_posts
      end

    # Also apply software filter if set
    filtered_posts = filter_posts_by_software(filtered_posts, socket.assigns.software_filter)
    filtered_posts = maybe_prioritize_non_community_posts(filtered_posts, socket)

    assign(socket, :filtered_posts, filtered_posts)
  end

  # Check if a post matches the URL-based filter (current_filter from URL params)
  defp post_matches_url_filter?(post, filter, socket) do
    case filter do
      "local" ->
        # Local posts have a sender_id (local user) and no remote_actor_id
        !is_nil(post.sender_id) && is_nil(post.remote_actor_id)

      "federated" ->
        # Only federated posts
        post.federated == true

      "following" ->
        # Posts from people the user follows
        if socket.assigns[:current_user] do
          cond do
            post.sender_id ->
              Social.following?(socket.assigns.current_user.id, post.sender_id)

            post.remote_actor_id ->
              Elektrine.Profiles.following_remote_actor?(
                socket.assigns.current_user.id,
                post.remote_actor_id
              )

            true ->
              false
          end
        else
          false
        end

      # "all" and "public" and unknown - allow all posts (but filter replies)
      _ ->
        is_nil(Map.get(post, :reply_to_id)) && is_nil(get_in(post.media_metadata, ["inReplyTo"]))
    end
  end

  # Check if a single post matches the current timeline filter
  defp post_matches_filter?(post, filter, socket) do
    case filter do
      "posts" ->
        is_nil(Map.get(post, :reply_to_id)) &&
          !PostUtilities.has_community_uri?(post)

      "replies" ->
        !is_nil(Map.get(post, :reply_to_id)) ||
          !is_nil(get_in(post.media_metadata, ["inReplyTo"]))

      "media" ->
        media_urls = Map.get(post, :media_urls, [])
        has_media_urls = !Enum.empty?(media_urls)
        link_preview = Map.get(post, :link_preview)

        has_link_preview =
          match?(%Elektrine.Social.LinkPreview{}, link_preview) &&
            link_preview.status == "success" &&
            link_preview.image_url != nil

        has_media_urls || has_link_preview

      "friends" ->
        post.sender_id && post.sender_id in socket.assigns.friend_ids

      "trusted" ->
        post.federated != true &&
          (post.sender || %{}) |> Map.get(:trust_level, 0) >= 2

      "communities" ->
        PostUtilities.has_community_uri?(post)

      "federated" ->
        post.federated == true

      "local" ->
        # Local posts have a sender_id (local user) and no remote_actor_id
        !is_nil(post.sender_id) && is_nil(post.remote_actor_id)

      "following" ->
        # For following filter, check if we follow the sender
        if socket.assigns[:current_user] do
          cond do
            post.sender_id ->
              Social.following?(socket.assigns.current_user.id, post.sender_id)

            post.remote_actor_id ->
              Elektrine.Profiles.following_remote_actor?(
                socket.assigns.current_user.id,
                post.remote_actor_id
              )

            true ->
              false
          end
        else
          false
        end

      # "all" filter - exclude replies to match DB query behavior
      "all" ->
        is_nil(Map.get(post, :reply_to_id)) && is_nil(get_in(post.media_metadata, ["inReplyTo"]))

      # Unknown filters - allow all posts
      _ ->
        true
    end
  end

  defp filter_posts_by_software(posts, "all"), do: posts

  defp filter_posts_by_software(posts, "local") do
    Enum.filter(posts, fn post -> !post.federated end)
  end

  defp filter_posts_by_software(posts, software) do
    # Collect unique domains from federated posts
    domains =
      posts
      |> Enum.filter(
        &(&1.federated && &1.remote_actor &&
            !match?(%Ecto.Association.NotLoaded{}, &1.remote_actor))
      )
      |> Enum.map(& &1.remote_actor.domain)
      |> Enum.uniq()

    # Use batch lookup - much faster than individual lookups
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

  # Match software with variants (e.g., Akkoma -> Pleroma, Calckey/Firefish -> Misskey)
  defp software_matches?(nil, _), do: false

  defp software_matches?(instance_sw, filter) do
    filter = String.downcase(filter)

    case filter do
      "pleroma" -> instance_sw in ["pleroma", "akkoma"]
      "misskey" -> instance_sw in ["misskey", "calckey", "firefish", "iceshrimp", "sharkey"]
      "mastodon" -> instance_sw in ["mastodon", "hometown", "glitch"]
      _ -> instance_sw == filter
    end
  end

  defp maybe_prioritize_non_community_posts(posts, socket) do
    if socket.assigns.current_filter in ["all", "following", "federated", "public"] &&
         socket.assigns.timeline_filter == "all" &&
         socket.assigns.software_filter == "all" do
      {non_community, community} =
        Enum.split_with(posts, fn post ->
          !PostUtilities.has_community_uri?(post)
        end)

      non_community ++ community
    else
      posts
    end
  end

  # Convert remote ActivityPub replies to a format compatible with the reply display
  defp convert_remote_replies_to_display_format(remote_replies) do
    remote_replies
    |> Enum.map(&convert_single_remote_reply/1)
    |> Enum.filter(&(&1 != nil))
  end

  # Convert Lemmy top-comment API payloads into interactive local federated messages
  # whenever possible. Falls back to read-only comment maps if materialization fails.
  defp materialize_lemmy_top_comments(post, comments) when is_list(comments) do
    comments
    |> Enum.map(&materialize_single_lemmy_comment(post, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp materialize_lemmy_top_comments(_post, _), do: []

  defp materialize_single_lemmy_comment(post, %{ap_id: ap_id} = comment) when is_binary(ap_id) do
    case Messaging.get_message_by_activitypub_ref(ap_id) do
      %Elektrine.Messaging.Message{} = existing ->
        merge_lemmy_comment_counts(existing, comment)

      nil ->
        create_lemmy_comment_message(post, comment)
    end
  end

  defp materialize_single_lemmy_comment(_post, comment), do: comment

  defp create_lemmy_comment_message(post, %{ap_id: ap_id, actor_id: actor_uri} = comment)
       when is_binary(actor_uri) and actor_uri != "" do
    with remote_actor when not is_nil(remote_actor) <-
           Elektrine.ActivityPub.get_actor_by_uri(actor_uri),
         {:ok, message} <-
           Messaging.create_federated_message(%{
             activitypub_id: ap_id,
             activitypub_url: ap_id,
             content: Map.get(comment, :content, ""),
             visibility: "public",
             post_type: "comment",
             message_type: "text",
             remote_actor_id: remote_actor.id,
             reply_to_id: post.id,
             inserted_at: parse_lemmy_published(Map.get(comment, :published)),
             like_count: Map.get(comment, :upvotes, 0),
             reply_count: Map.get(comment, :child_count, 0),
             share_count: 0
           }) do
      merge_lemmy_comment_counts(%{message | remote_actor: remote_actor}, comment)
    else
      nil ->
        comment

      {:error, %Ecto.Changeset{errors: [activitypub_id: {"has already been taken", _}]}} ->
        case Messaging.get_message_by_activitypub_ref(ap_id) do
          %Elektrine.Messaging.Message{} = existing ->
            merge_lemmy_comment_counts(existing, comment)

          _ ->
            comment
        end

      _ ->
        comment
    end
  end

  defp create_lemmy_comment_message(_post, comment), do: comment

  defp merge_lemmy_comment_counts(%Elektrine.Messaging.Message{} = message, comment) do
    %{
      message
      | like_count: max(message.like_count || 0, Map.get(comment, :upvotes, 0)),
        reply_count: max(message.reply_count || 0, Map.get(comment, :child_count, 0))
    }
  end

  defp parse_lemmy_published(nil), do: DateTime.utc_now()

  defp parse_lemmy_published(published) when is_binary(published) do
    case DateTime.from_iso8601(published) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp parse_lemmy_published(_), do: DateTime.utc_now()

  defp convert_single_remote_reply(reply_object) when is_map(reply_object) do
    # Extract actor URI
    actor_uri = extract_actor_uri(reply_object)
    return_nil = fn -> nil end

    if is_binary(actor_uri) do
      # Timeline rendering is local-first: never fetch remote actors in the read path.
      case Elektrine.ActivityPub.get_actor_by_uri(actor_uri) do
        nil ->
          return_nil.()

        remote_actor ->
          # Parse the published date
          published =
            case reply_object["published"] do
              nil ->
                DateTime.utc_now()

              date_str ->
                case DateTime.from_iso8601(date_str) do
                  {:ok, dt, _} -> dt
                  _ -> DateTime.utc_now()
                end
            end

          # Extract content (handle HTML content)
          content =
            reply_object["content"] ||
              extract_content_from_map(reply_object["contentMap"]) ||
              ""

          fallback_avatar_url = extract_reply_avatar_fallback(reply_object)

          remote_actor =
            if is_binary(fallback_avatar_url) &&
                 fallback_avatar_url != "" &&
                 is_nil(remote_actor.avatar_url) do
              %{remote_actor | avatar_url: fallback_avatar_url}
            else
              remote_actor
            end

          local_message = Messaging.get_message_by_activitypub_ref(reply_object["id"])

          interaction_id =
            if match?(%Elektrine.Messaging.Message{}, local_message) do
              local_message.id
            else
              reply_object["id"]
            end

          # Create a struct-like map compatible with the reply display
          %{
            id: interaction_id,
            activitypub_id: (local_message && local_message.activitypub_id) || reply_object["id"],
            content: (local_message && local_message.content) || content,
            inserted_at: (local_message && local_message.inserted_at) || published,
            like_count:
              max(
                (local_message && local_message.like_count) || 0,
                Elektrine.ActivityPub.Helpers.extract_interaction_count(reply_object, "likes")
              ),
            share_count:
              max(
                (local_message && local_message.share_count) || 0,
                Elektrine.ActivityPub.Helpers.extract_interaction_count(reply_object, "shares")
              ),
            reply_count:
              max(
                (local_message && local_message.reply_count) || 0,
                Elektrine.ActivityPub.Helpers.extract_interaction_count(reply_object, "replies")
              ),
            sender: nil,
            sender_id: nil,
            remote_actor: (local_message && local_message.remote_actor) || remote_actor,
            remote_actor_id: remote_actor.id,
            federated: true,
            media_urls: extract_media_urls(reply_object),
            visibility: "public"
          }
      end
    else
      return_nil.()
    end
  end

  defp convert_single_remote_reply(_), do: nil

  defp allow_timeline_read(socket, action) do
    TimelineRateLimiter.allow_read(timeline_rate_limit_identifier(socket, action))
  end

  defp timeline_rate_limit_identifier(socket, action) do
    actor =
      case socket.assigns[:current_user] do
        %{id: user_id} -> "user:#{user_id}"
        _ -> "anon:#{socket.id || "unknown"}"
      end

    "liveview:#{action}:#{actor}"
  end

  defp normalize_timeline_view(nil), do: "all"

  defp normalize_timeline_view(view)
       when view in [
              "all",
              "posts",
              "replies",
              "media",
              "friends",
              "my_posts",
              "trusted",
              "communities",
              "federated",
              "local",
              "following"
            ],
       do: view

  defp normalize_timeline_view(_), do: "all"

  defp extract_actor_uri(%{"attributedTo" => uri}) when is_binary(uri), do: uri
  defp extract_actor_uri(%{"attributedTo" => [uri | _]}) when is_binary(uri), do: uri
  defp extract_actor_uri(%{"attributedTo" => %{"id" => uri}}) when is_binary(uri), do: uri
  defp extract_actor_uri(_), do: nil

  defp extract_content_from_map(content_map) when is_map(content_map) do
    content_map
    |> Map.values()
    |> Enum.find(&is_binary/1)
  end

  defp extract_content_from_map(_), do: nil

  defp extract_reply_avatar_fallback(reply_object) do
    mastodon_avatar =
      case Map.get(reply_object, "_mastodon_account") do
        account when is_map(account) ->
          Map.get(account, :avatar) || Map.get(account, "avatar")

        _ ->
          nil
      end

    lemmy_avatar =
      case Map.get(reply_object, "_lemmy") do
        lemmy when is_map(lemmy) ->
          Map.get(lemmy, "creator_avatar") || Map.get(lemmy, :creator_avatar)

        _ ->
          nil
      end

    mastodon_avatar || lemmy_avatar
  end

  # Extract media URLs from an ActivityPub object
  defp extract_media_urls(object) do
    case object["attachment"] do
      attachments when is_list(attachments) ->
        attachments
        |> Enum.filter(fn att ->
          att["type"] in ["Image", "Document"] ||
            (att["mediaType"] && String.starts_with?(att["mediaType"], "image/"))
        end)
        |> Enum.map(fn att -> att["url"] end)
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  end
end
