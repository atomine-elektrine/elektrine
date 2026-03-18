defmodule ElektrineWeb.TimelineLive.Index do
  use ElektrineSocialWeb, :live_view
  require Logger
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.PubSubTopics
  alias Elektrine.RSS
  alias Elektrine.Social
  alias Elektrine.Social.Recommendations
  alias Elektrine.Timeline.RateLimiter, as: TimelineRateLimiter
  alias ElektrineWeb.Components.Social.PostUtilities
  alias ElektrineWeb.TimelineLive.ReplyContextPreviews
  import ElektrineWeb.Components.Social.RSSItem
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Live.Helpers.PostStateHelpers
  alias ElektrineWeb.TimelineLive.Operations.Helpers, as: TimelineHelpers
  alias ElektrineWeb.TimelineLive.Operations.PostOperations
  alias ElektrineWeb.TimelineLive.Router
  @remote_replies_poll_interval_ms 1500
  @remote_replies_poll_max_attempts 6
  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    friends =
      if user do
        Elektrine.Friends.list_friends(user.id)
      else
        []
      end

    friend_ids = Enum.map(friends, & &1.id)

    if connected?(socket) do
      if user do
        PubSubTopics.subscribe(PubSubTopics.user_timeline(user.id))
        PubSubTopics.subscribe(PubSubTopics.timeline_all())
      end

      PubSubTopics.subscribe(PubSubTopics.timeline_public())
    end

    socket =
      socket
      |> assign(:page_title, "Timeline")
      |> assign(:base_timeline_posts, [])
      |> assign(:base_timeline_key, nil)
      |> assign(:special_view_cache, %{})
      |> assign(:timeline_posts, [])
      |> assign(:post_replies, %{})
      |> assign(:loading_remote_replies, MapSet.new())
      |> assign(:manual_loading_remote_replies, MapSet.new())
      |> assign(
        :current_filter,
        default_source_filter(user)
      )
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
      |> assign(:composer_intent, "post")
      |> assign(:loading_more, false)
      |> assign(:no_more_posts, false)
      |> assign(:reply_to_post, nil)
      |> assign(:reply_to_post_recent_replies, [])
      |> assign(:reply_content, "")
      |> assign(:reply_to_reply_id, nil)
      |> assign(:timeline_filter, "all")
      |> assign(:filter_dropdown_open, false)
      |> assign(:filtered_posts, [])
      |> assign(:filtered_post_ids, [])
      |> assign(:user_communities, [])
      |> assign(:available_conversations, [])
      |> assign(:user_likes, %{})
      |> assign(:user_downvotes, %{})
      |> assign(:post_interactions, %{})
      |> assign(:post_reactions, %{})
      |> assign(:user_follows, %{})
      |> assign(:pending_follows, %{})
      |> assign(:remote_follow_overrides, %{})
      |> assign(:user_boosts, %{})
      |> assign(:user_saves, %{})
      |> assign(:show_report_modal, false)
      |> assign(:report_type, nil)
      |> assign(:report_id, nil)
      |> assign(:report_metadata, %{})
      |> assign(:remote_user_preview, nil)
      |> assign(:remote_user_loading, false)
      |> assign(:friends, friends)
      |> assign(:friend_ids, friend_ids)
      |> assign(:show_image_upload_modal, false)
      |> assign(:pending_media_urls, [])
      |> assign(:pending_media_attachments, [])
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
      |> assign(:search_query, "")
      |> assign(:session_context, %{})
      |> assign(:show_mobile_filters, false)
      |> assign(:user_drafts, [])
      |> assign(:show_drafts_panel, false)
      |> assign(:editing_draft_id, nil)
      |> assign(:draft_auto_saved, false)
      |> assign(:draft_saving, false)
      |> assign(:loading_timeline, true)
      |> stream(:timeline_filtered_posts, [], reset: true)

    socket =
      if user do
        allow_upload(socket, :timeline_attachments,
          accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav),
          max_entries: 4,
          max_file_size: 50_000_000
        )
      else
        socket
      end

    if connected?(socket) do
      send(self(), :load_timeline_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = normalize_source_filter(params["filter"], socket.assigns[:current_user])
    timeline_view = normalize_timeline_view(params["view"] || socket.assigns.timeline_filter)
    search_query = normalize_search_query(params["q"] || socket.assigns.search_query)
    composer_intent = normalize_composer_intent(params["composer"])

    socket =
      maybe_apply_composer_intent(
        socket,
        composer_intent,
        socket.assigns[:current_user]
      )

    cond do
      socket.assigns.loading_timeline ->
        {:noreply,
         socket
         |> assign(:current_filter, filter)
         |> assign(:timeline_filter, timeline_view)
         |> assign(:search_query, search_query)}

      search_query != socket.assigns.search_query ->
        {:noreply,
         socket
         |> assign(:search_query, search_query)
         |> queue_timeline_reload(filter, timeline_view)}

      filter != socket.assigns.current_filter ->
        {:noreply, queue_timeline_reload(socket, filter, timeline_view)}

      timeline_view != socket.assigns.timeline_filter ->
        updated_socket =
          socket
          |> assign(:timeline_filter, timeline_view)
          |> prune_queued_posts_for_active_filters()

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
    search_query = socket.assigns.search_query
    session_context = socket.assigns[:session_context] || %{}
    filter_changed = filter != socket.assigns.current_filter
    special_view_cache = socket.assigns[:special_view_cache] || %{}
    cache_key = {filter, timeline_view, search_query}

    filter_context_socket =
      socket
      |> assign(:current_filter, filter)
      |> assign(:timeline_filter, timeline_view)
      |> assign(:search_query, search_query)

    cached_special_view = Map.get(special_view_cache, cache_key)

    posts =
      case cached_special_view do
        %{posts: cached_posts} ->
          cached_posts

        _ ->
          load_posts_for_filter(filter, user, timeline_view,
            search_query: search_query,
            session_context: session_context
          )
      end

    cached_post_replies =
      case cached_special_view do
        %{post_replies: cached_replies} when is_map(cached_replies) -> cached_replies
        _ -> %{}
      end

    base_timeline_posts =
      cond do
        !view_requires_data_reload?(timeline_view) ->
          posts

        filter_changed ->
          load_posts_for_filter(filter, user, "all",
            search_query: search_query,
            session_context: session_context
          )

        socket.assigns.base_timeline_key == {filter, search_query} &&
            socket.assigns.base_timeline_posts != [] ->
          socket.assigns.base_timeline_posts

        true ->
          load_posts_for_filter(filter, user, "all",
            search_query: search_query,
            session_context: session_context
          )
      end

    special_view_cache =
      Map.put(special_view_cache, cache_key, %{posts: posts, post_replies: cached_post_replies})

    queued_posts = queued_posts_for_active_filters(filter_context_socket)

    {rss_items, rss_saves} =
      cond do
        filter in ["rss", "explore", "home"] && user ->
          items =
            user.id
            |> RSS.get_timeline_items(limit: 20)
            |> filter_rss_items_by_query(search_query)

          item_ids = Enum.map(items, & &1.id)
          saves = Social.list_user_saved_rss_items(user.id, item_ids)
          saves_map = Enum.into(saves, %{}, fn id -> {id, true} end)
          {items, saves_map}

        filter == "saved" && user ->
          items =
            user.id
            |> Social.get_saved_rss_items(limit: 20)
            |> filter_rss_items_by_query(search_query)

          saves_map = Enum.into(items, %{}, fn item -> {item.id, true} end)
          {items, saves_map}

        true ->
          {[], %{}}
      end

    {:noreply,
     socket
     |> assign(:current_filter, filter)
     |> assign(:base_timeline_posts, base_timeline_posts)
     |> assign(:base_timeline_key, {filter, search_query})
     |> assign(:special_view_cache, special_view_cache)
     |> assign(:timeline_posts, posts)
     |> assign(:queued_posts, queued_posts)
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
     |> maybe_queue_reply_context_previews(posts)
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

  defp maybe_queue_reply_context_previews(socket, posts) do
    refs = ReplyContextPreviews.candidate_refs(posts)

    if connected?(socket) && refs != [] do
      send(self(), {:load_reply_context_previews, refs})
    end

    socket
  end

  defp remote_posts_needing_fetch(posts, socket) when is_list(posts) do
    lemmy_counts = socket.assigns[:lemmy_counts] || %{}
    remote_post_data = socket.assigns[:remote_post_data] || %{}
    post_replies = socket.assigns[:post_replies] || %{}

    posts
    |> Enum.filter(fn post ->
      if post.federated && is_binary(post.activitypub_id) do
        ap_id = post.activitypub_id
        lemmy_post? = PostUtilities.community_post?(post)
        has_top_replies? = Map.get(post_replies, post.id, []) != []
        missing_lemmy_counts = lemmy_post? && !Map.has_key?(lemmy_counts, ap_id)
        missing_remote_post_data = !lemmy_post? && !Map.has_key?(remote_post_data, ap_id)
        missing_lemmy_top_comments = lemmy_post? && !has_top_replies?
        missing_lemmy_counts || missing_remote_post_data || missing_lemmy_top_comments
      else
        false
      end
    end)
  end

  defp remote_posts_needing_fetch(_, _) do
    []
  end

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

  defp maybe_schedule_background_refresh(socket, _posts) do
    socket
  end

  defp maybe_schedule_reply_ingestion(socket, posts) when is_list(posts) do
    if connected?(socket) do
      existing_replies = socket.assigns[:post_replies] || %{}

      message_ids =
        posts
        |> Enum.filter(&(&1.federated == true && is_integer(&1.id) && (&1.reply_count || 0) > 0))
        |> Enum.reject(fn post -> Map.get(existing_replies, post.id, []) != [] end)
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

  defp maybe_schedule_reply_ingestion(socket, _posts) do
    socket
  end

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
        user_likes:
          if user_id do
            get_user_likes(user_id, all_messages)
          else
            %{}
          end,
        user_follows:
          if user_id do
            get_user_follows(user_id, all_messages)
          else
            %{}
          end,
        pending_follows:
          if user_id do
            get_pending_follows(user_id, all_messages)
          else
            %{}
          end,
        user_boosts:
          if user_id do
            get_user_boosts(user_id, all_messages)
          else
            %{}
          end,
        user_saves:
          if user_id do
            get_user_saves(user_id, all_messages)
          else
            %{}
          end
      }

      send(parent, {:timeline_hydrated, hydration_ref, filter, timeline_view, hydrated_state})
    end)

    assign(socket, :timeline_hydration_ref, hydration_ref)
  end

  @impl true
  def handle_event(event_name, params, socket) do
    Router.route_event(event_name, params, socket)
  end

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
        cache_key = {filter, timeline_view, socket.assigns.search_query}
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
         |> assign(:user_saves, Map.get(hydrated_state, :user_saves, %{}))
         |> TimelineHelpers.refresh_filtered_posts_stream()}
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
        if user do
          Elektrine.Social.Drafts.list_drafts(user.id, limit: 20)
        else
          []
        end
      )

    if user do
      send(self(), :load_secondary_data)
    end

    {:noreply, loaded_socket}
  end

  @impl true
  def handle_info(:load_secondary_data, socket) do
    user = socket.assigns.current_user
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
      if timeline_remote_enrichment_enabled?() do
        remote_posts_needing_fetch(posts, socket)
      else
        []
      end

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
  def handle_info({:load_reply_context_previews, refs}, socket) do
    if refs == [] do
      {:noreply, socket}
    else
      parent = self()

      Task.start(fn ->
        previews = ReplyContextPreviews.fetch_local_previews(refs)
        send(parent, {:reply_context_previews_loaded, previews})
      end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:reply_context_previews_loaded, previews}, socket) do
    if previews == %{} do
      {:noreply, socket}
    else
      update_fn = &ReplyContextPreviews.apply_previews(&1, previews)

      updated_cache =
        Enum.reduce(socket.assigns.special_view_cache || %{}, %{}, fn {key, entry}, acc ->
          updated_entry =
            entry
            |> Map.update(:posts, [], fn
              posts when is_list(posts) -> update_fn.(posts)
              posts -> posts
            end)

          Map.put(acc, key, updated_entry)
        end)

      {:noreply,
       socket
       |> assign(:timeline_posts, update_fn.(socket.assigns.timeline_posts || []))
       |> assign(:base_timeline_posts, update_fn.(socket.assigns.base_timeline_posts || []))
       |> assign(:queued_posts, update_fn.(socket.assigns.queued_posts || []))
       |> assign(:special_view_cache, updated_cache)
       |> apply_timeline_filter()}
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
       |> assign(:post_replies, updated_post_replies)
       |> TimelineHelpers.refresh_filtered_posts(Enum.map(posts, & &1.id))}
    end
  end

  @impl true
  def handle_info(:refresh_remote_counts, socket) do
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
    update_fn = &update_posts_for_counts(&1, message_id, counts)

    updated_replies =
      update_reply_previews_for_counts(socket.assigns.post_replies, message_id, counts)

    updated_socket =
      socket
      |> TimelineHelpers.update_cached_posts(update_fn)
      |> assign(:post_replies, updated_replies)

    message_post =
      find_message_post(updated_socket.assigns.timeline_posts, message_id) ||
        find_message_post(updated_socket.assigns.base_timeline_posts || [], message_id)

    updated_lemmy_counts =
      if message_post && is_binary(message_post.activitypub_id) do
        existing = Map.get(socket.assigns.lemmy_counts || %{}, message_post.activitypub_id, %{})

        Map.put(
          socket.assigns.lemmy_counts || %{},
          message_post.activitypub_id,
          existing
          |> Map.put(:score, counts.like_count)
          |> Map.put(:comments, counts.reply_count)
        )
      else
        socket.assigns.lemmy_counts || %{}
      end

    {:noreply,
     updated_socket
     |> assign(:lemmy_counts, updated_lemmy_counts)
     |> clear_post_interaction_state(message_id)
     |> TimelineHelpers.refresh_interaction_posts(message_id)}
  end

  @impl true
  def handle_info({:remote_user_fetched, actor}, socket) do
    {:noreply, assign(socket, remote_user_preview: actor, remote_user_loading: false)}
  end

  def handle_info({:remote_user_fetch_failed, _handle}, socket) do
    {:noreply,
     socket |> assign(:remote_user_loading, false) |> put_flash(:error, "Could not find user")}
  end

  def handle_info({:follow_accepted, remote_actor_id}, socket) do
    updated_pending =
      socket.assigns.pending_follows
      |> Map.delete({:remote, remote_actor_id})
      |> Map.delete(remote_actor_id)

    updated_follows =
      socket.assigns.user_follows
      |> Map.put({:remote, remote_actor_id}, true)
      |> Map.put(remote_actor_id, true)

    {:noreply,
     socket
     |> assign(:pending_follows, updated_pending)
     |> assign(:user_follows, updated_follows)
     |> TimelineHelpers.put_remote_follow_override(remote_actor_id, :following)
     |> TimelineHelpers.push_remote_follow_state(remote_actor_id, :following)}
  end

  @impl true
  def handle_info(:all_notifications_read, socket) do
    {:noreply, assign(socket, :notification_count, 0)}
  end

  @impl true
  def handle_info(:notification_updated, socket) do
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
    {:noreply, assign(socket, :notification_count, count)}
  end

  @impl true
  def handle_info({:new_timeline_post, post}, socket) do
    if socket.assigns[:current_user] && post.sender_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      preload_timeline_post_async(post, :timeline)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_post_preloaded, :timeline, post_with_associations}, socket) do
    updated_socket = socket

    updated_socket =
      if post_with_associations.sender_id && socket.assigns[:current_user] do
        follow_key = {:local, post_with_associations.sender_id}

        if Map.has_key?(socket.assigns.user_follows, follow_key) do
          updated_socket
        else
          is_following =
            Social.following?(socket.assigns.current_user.id, post_with_associations.sender_id)

          update(updated_socket, :user_follows, &Map.put(&1, follow_key, is_following))
        end
      else
        updated_socket
      end

    updated_socket =
      if post_with_associations.remote_actor_id && socket.assigns[:current_user] do
        follow_key = {:remote, post_with_associations.remote_actor_id}

        if Map.has_key?(socket.assigns.user_follows, follow_key) do
          updated_socket
        else
          is_following =
            Elektrine.Profiles.following_remote_actor?(
              socket.assigns.current_user.id,
              post_with_associations.remote_actor_id
            )

          update(updated_socket, :user_follows, &Map.put(&1, follow_key, is_following))
        end
      else
        updated_socket
      end

    post_id = post_with_associations.id
    already_queued = Enum.any?(updated_socket.assigns.queued_posts, fn p -> p.id == post_id end)

    already_in_timeline =
      Enum.any?(updated_socket.assigns.timeline_posts, fn p -> p.id == post_id end)

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

    matches_software_filter =
      post_matches_software_filter?(
        post_with_associations,
        updated_socket.assigns.software_filter
      )

    matches_search_query =
      TimelineHelpers.filter_posts_by_search_query(
        [post_with_associations],
        updated_socket.assigns[:search_query]
      ) != []

    matches_filter =
      matches_url_filter && matches_timeline_filter && matches_software_filter &&
        matches_search_query

    updated_socket =
      if already_queued || already_in_timeline || !matches_filter do
        updated_socket
      else
        update(updated_socket, :queued_posts, fn queued -> [post_with_associations | queued] end)
      end

    refs = ReplyContextPreviews.candidate_refs([post_with_associations])

    if refs != [] do
      send(self(), {:load_reply_context_previews, refs})
    end

    {:noreply, updated_socket}
  end

  @impl true
  def handle_info({:new_public_post, post}, socket) do
    if socket.assigns[:current_user] && post.sender_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      preload_timeline_post_async(post, :public)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:refresh_remote_replies, post_id, attempt}, socket) do
    user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    replies =
      if user_id do
        Social.get_direct_replies_for_posts([post_id], user_id: user_id, limit_per_post: 20)
        |> Map.get(post_id, [])
      else
        Social.get_direct_replies_for_posts([post_id], limit_per_post: 20) |> Map.get(post_id, [])
      end

    cond do
      replies != [] ->
        send(self(), {:post_replies_loaded, post_id, replies})
        {:noreply, socket}

      attempt < @remote_replies_poll_max_attempts ->
        Process.send_after(
          self(),
          {:refresh_remote_replies, post_id, attempt + 1},
          @remote_replies_poll_interval_ms
        )

        {:noreply, socket}

      true ->
        loading_set = MapSet.delete(socket.assigns.loading_remote_replies, post_id)
        manual_loading_set = MapSet.delete(socket.assigns.manual_loading_remote_replies, post_id)

        {:noreply,
         socket
         |> assign(:loading_remote_replies, loading_set)
         |> assign(:manual_loading_remote_replies, manual_loading_set)
         |> TimelineHelpers.refresh_filtered_post(post_id)}
    end
  end

  @impl true
  def handle_info({:new_post_preloaded, :public, post_with_associations}, socket) do
    matches_url_filter =
      post_matches_url_filter?(post_with_associations, socket.assigns.current_filter, socket)

    matches_timeline_filter =
      post_matches_filter?(post_with_associations, socket.assigns.timeline_filter, socket)

    matches_software_filter =
      post_matches_software_filter?(post_with_associations, socket.assigns.software_filter)

    matches_search_query =
      TimelineHelpers.filter_posts_by_search_query(
        [post_with_associations],
        socket.assigns[:search_query]
      ) != []

    if !matches_url_filter || !matches_timeline_filter || !matches_software_filter ||
         !matches_search_query do
      {:noreply, socket}
    else
      updated_socket =
        if socket.assigns[:current_user] do
          updated_socket =
            if post_with_associations.sender_id do
              follow_key = {:local, post_with_associations.sender_id}

              if Map.has_key?(socket.assigns.user_follows, follow_key) do
                socket
              else
                is_following =
                  Social.following?(
                    socket.assigns.current_user.id,
                    post_with_associations.sender_id
                  )

                update(socket, :user_follows, &Map.put(&1, follow_key, is_following))
              end
            else
              socket
            end

          if post_with_associations.remote_actor_id do
            follow_key = {:remote, post_with_associations.remote_actor_id}

            if Map.has_key?(updated_socket.assigns.user_follows, follow_key) do
              updated_socket
            else
              is_following =
                Elektrine.Profiles.following_remote_actor?(
                  socket.assigns.current_user.id,
                  post_with_associations.remote_actor_id
                )

              update(updated_socket, :user_follows, &Map.put(&1, follow_key, is_following))
            end
          else
            updated_socket
          end
        else
          socket
        end

      post_id = post_with_associations.id
      already_queued = Enum.any?(updated_socket.assigns.queued_posts, fn p -> p.id == post_id end)

      already_in_timeline =
        Enum.any?(updated_socket.assigns.timeline_posts, fn p -> p.id == post_id end)

      updated_socket =
        if already_queued || already_in_timeline do
          updated_socket
        else
          update(updated_socket, :queued_posts, fn queued -> [post_with_associations | queued] end)
        end

      refs = ReplyContextPreviews.candidate_refs([post_with_associations])

      if refs != [] do
        send(self(), {:load_reply_context_previews, refs})
      end

      {:noreply, updated_socket}
    end
  end

  @impl true
  def handle_info({:post_liked, %{message_id: message_id, like_count: like_count}}, socket) do
    updated_posts =
      Enum.map(socket.assigns.timeline_posts, fn post ->
        if post.id == message_id do
          %{post | like_count: like_count}
        else
          post
        end
      end)

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
     |> clear_post_interaction_state(message_id)
     |> TimelineHelpers.refresh_interaction_posts(message_id)}
  end

  @impl true
  def handle_info({:post_replies_loaded, post_id, replies}, socket) do
    updated_post_replies = Map.put(socket.assigns.post_replies, post_id, replies)
    loading_set = MapSet.delete(socket.assigns.loading_remote_replies, post_id)
    manual_loading_set = MapSet.delete(socket.assigns.manual_loading_remote_replies, post_id)

    {:noreply,
     socket
     |> assign(:post_replies, updated_post_replies)
     |> assign(:loading_remote_replies, loading_set)
     |> assign(:manual_loading_remote_replies, manual_loading_set)
     |> TimelineHelpers.refresh_filtered_post(post_id)}
  end

  @impl true
  def handle_info({:remote_replies_loaded, post_id, remote_replies}, socket) do
    converted_replies = convert_remote_replies_to_display_format(remote_replies)
    existing_replies = Map.get(socket.assigns.post_replies, post_id, [])
    merged_replies = merge_reply_previews(existing_replies, converted_replies)

    updated_post_replies =
      if merged_replies == [] do
        socket.assigns.post_replies
      else
        Map.put(socket.assigns.post_replies, post_id, merged_replies)
      end

    updated_recent_replies =
      case socket.assigns.reply_to_post do
        %{id: ^post_id} ->
          merge_reply_previews(socket.assigns.reply_to_post_recent_replies, converted_replies)

        _ ->
          socket.assigns.reply_to_post_recent_replies
      end

    manual_loading? = MapSet.member?(socket.assigns.manual_loading_remote_replies, post_id)

    loading_set =
      if manual_loading? and merged_replies == [] do
        socket.assigns.loading_remote_replies
      else
        MapSet.delete(socket.assigns.loading_remote_replies, post_id)
      end

    manual_loading_set =
      if merged_replies == [] do
        socket.assigns.manual_loading_remote_replies
      else
        MapSet.delete(socket.assigns.manual_loading_remote_replies, post_id)
      end

    {:noreply,
     socket
     |> assign(:post_replies, updated_post_replies)
     |> assign(:reply_to_post_recent_replies, updated_recent_replies)
     |> assign(:loading_remote_replies, loading_set)
     |> assign(:manual_loading_remote_replies, manual_loading_set)
     |> TimelineHelpers.refresh_filtered_post(post_id)}
  end

  @impl true
  def handle_info({:reply_count_updated, message_id, new_count}, socket) do
    updated_posts =
      Enum.map(socket.assigns.timeline_posts, fn post ->
        if post.id == message_id do
          %{post | reply_count: new_count}
        else
          post
        end
      end)

    {:noreply, socket |> assign(:timeline_posts, updated_posts) |> apply_timeline_filter()}
  end

  @impl true
  def handle_info({:load_followed_user_posts, user_id}, socket) do
    current_user_id = socket.assigns.current_user.id

    new_user_posts =
      Social.get_user_timeline_posts(user_id, limit: 20, viewer_id: current_user_id)

    updated_posts = merge_and_sort_posts(socket.assigns.timeline_posts, new_user_posts)

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
    message_id = reaction.message_id
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])
    already_present = Enum.any?(post_reactions, fn r -> r.id == reaction.id end)

    updated_reactions =
      if already_present do
        current_reactions
      else
        Map.put(current_reactions, message_id, [reaction | post_reactions])
      end

    {:noreply,
     socket
     |> assign(:post_reactions, updated_reactions)
     |> TimelineHelpers.refresh_filtered_post(message_id)}
  end

  @impl true
  def handle_info({:post_reaction_removed, reaction}, socket) do
    message_id = reaction.message_id
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])

    updated_post_reactions =
      Enum.reject(post_reactions, fn r ->
        r.emoji == reaction.emoji && r.user_id == reaction.user_id
      end)

    updated_reactions = Map.put(current_reactions, message_id, updated_post_reactions)

    {:noreply,
     socket
     |> assign(:post_reactions, updated_reactions)
     |> TimelineHelpers.refresh_filtered_post(message_id)}
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

  defp load_posts_for_filter(filter, user, timeline_view, opts) do
    search_query = Keyword.get(opts, :search_query, "")
    session_context = Keyword.get(opts, :session_context, %{})

    case timeline_view do
      "communities" ->
        if user do
          Social.get_public_community_posts(
            limit: 20,
            user_id: user.id,
            search_query: search_query
          )
        else
          Social.get_public_community_posts(limit: 20, search_query: search_query)
        end

      "replies" ->
        Social.get_federated_replies(
          limit: 20,
          user_id: user && user.id,
          search_query: search_query
        )

      "friends" ->
        if user do
          Social.get_friends_timeline(user.id, limit: 20, search_query: search_query)
        else
          []
        end

      "my_posts" ->
        if user do
          Social.get_user_timeline_posts(user.id,
            limit: 20,
            viewer_id: user.id,
            search_query: search_query
          )
        else
          []
        end

      "trusted" ->
        Social.get_trusted_timeline(
          limit: 20,
          user_id: user && user.id,
          search_query: search_query
        )

      _ ->
        case filter do
          "home" ->
            if user do
              Social.get_combined_feed(user.id, limit: 20, search_query: search_query)
            else
              Social.get_public_timeline(limit: 20, search_query: search_query)
            end

          "for_you" ->
            if user do
              recommendation_limit =
                if search_query == "" do
                  20
                else
                  100
                end

              user.id
              |> Recommendations.get_for_you_feed(
                limit: recommendation_limit,
                session_context: session_context
              )
              |> TimelineHelpers.filter_posts_by_search_query(search_query)
              |> Enum.take(20)
            else
              Social.get_public_timeline(limit: 20, search_query: search_query)
            end

          "all" ->
            if user do
              Social.get_public_timeline(limit: 20, user_id: user.id, search_query: search_query)
            else
              Social.get_public_timeline(limit: 20, search_query: search_query)
            end

          "local" ->
            if user do
              Social.get_local_timeline(limit: 20, user_id: user.id, search_query: search_query)
            else
              Social.get_local_timeline(limit: 20, search_query: search_query)
            end

          "federated" ->
            Social.get_public_federated_posts(limit: 20, search_query: search_query)

          "saved" ->
            if user do
              Social.get_saved_posts(user.id, limit: 20, search_query: search_query)
            else
              []
            end

          "rss" ->
            []

          _ ->
            if user do
              Social.get_public_timeline(limit: 20, user_id: user.id, search_query: search_query)
            else
              Social.get_public_timeline(limit: 20, search_query: search_query)
            end
        end
    end
  end

  defp view_requires_data_reload?(timeline_view) do
    timeline_view in ["communities", "replies", "friends", "my_posts", "trusted"]
  end

  defp preload_timeline_post_async(post, source) do
    parent = self()

    Task.start(fn ->
      post_with_associations =
        Elektrine.Repo.preload(post, MessagingMessages.timeline_post_preloads())

      send(parent, {:new_post_preloaded, source, post_with_associations})
    end)
  end

  defp error_to_string(:too_large) do
    "File is too large (max 50MB)"
  end

  defp error_to_string(:not_accepted) do
    "Invalid file type. Supported: Images (JPG, PNG, GIF, WEBP), Videos (MP4, WEBM, OGV, MOV), Audio (MP3, WAV)"
  end

  defp error_to_string(:too_many_files) do
    "Maximum 4 files allowed"
  end

  defp error_to_string(_) do
    "Upload error"
  end

  defp merge_and_sort_posts(existing_posts, new_posts) do
    (existing_posts ++ new_posts)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
  end

  defp apply_timeline_filter(socket) do
    filtered_posts =
      case socket.assigns.timeline_filter do
        "posts" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            is_nil(Map.get(post, :reply_to_id)) && !PostUtilities.community_post?(post)
          end)

        "replies" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
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
                link_preview.status == "success" && link_preview.image_url != nil

            has_media_urls || has_link_preview
          end)

        "friends" ->
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
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.federated != true && (post.sender || %{}) |> Map.get(:trust_level, 0) >= 2
          end)

        "communities" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            PostUtilities.community_post?(post)
          end)

        "federated" ->
          Enum.filter(socket.assigns.timeline_posts, fn post -> post.federated == true end)

        "local" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            !is_nil(post.sender_id) && is_nil(post.remote_actor_id)
          end)

        _ ->
          socket.assigns.timeline_posts
      end

    filtered_posts = filter_posts_by_software(filtered_posts, socket.assigns.software_filter)

    filtered_posts =
      TimelineHelpers.filter_posts_by_search_query(filtered_posts, socket.assigns[:search_query])

    filtered_posts = maybe_prioritize_non_community_posts(filtered_posts, socket)
    TimelineHelpers.assign_filtered_posts(socket, filtered_posts)
  end

  defp post_matches_url_filter?(post, filter, socket) do
    case filter do
      "home" ->
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

      "for_you" ->
        false

      "local" ->
        !is_nil(post.sender_id) && is_nil(post.remote_actor_id)

      "federated" ->
        post.federated == true

      "following" ->
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

      "saved" ->
        false

      "rss" ->
        false

      _ ->
        is_nil(Map.get(post, :reply_to_id)) && is_nil(get_in(post.media_metadata, ["inReplyTo"]))
    end
  end

  defp post_matches_filter?(post, filter, socket) do
    case filter do
      "posts" ->
        is_nil(Map.get(post, :reply_to_id)) && !PostUtilities.community_post?(post)

      "replies" ->
        !is_nil(Map.get(post, :reply_to_id)) ||
          !is_nil(get_in(post.media_metadata, ["inReplyTo"]))

      "media" ->
        media_urls = Map.get(post, :media_urls, [])
        has_media_urls = !Enum.empty?(media_urls)
        link_preview = Map.get(post, :link_preview)

        has_link_preview =
          match?(%Elektrine.Social.LinkPreview{}, link_preview) &&
            link_preview.status == "success" && link_preview.image_url != nil

        has_media_urls || has_link_preview

      "friends" ->
        post.sender_id && post.sender_id in socket.assigns.friend_ids

      "trusted" ->
        post.federated != true && (post.sender || %{}) |> Map.get(:trust_level, 0) >= 2

      "communities" ->
        PostUtilities.community_post?(post)

      "federated" ->
        post.federated == true

      "local" ->
        !is_nil(post.sender_id) && is_nil(post.remote_actor_id)

      "following" ->
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

      "all" ->
        is_nil(Map.get(post, :reply_to_id)) && is_nil(get_in(post.media_metadata, ["inReplyTo"]))

      _ ->
        true
    end
  end

  defp prune_queued_posts_for_active_filters(socket) do
    assign(socket, :queued_posts, queued_posts_for_active_filters(socket))
  end

  defp queued_posts_for_active_filters(socket) do
    Enum.filter(socket.assigns.queued_posts || [], fn post ->
      post_matches_url_filter?(post, socket.assigns.current_filter, socket) &&
        post_matches_filter?(post, socket.assigns.timeline_filter, socket) &&
        post_matches_software_filter?(post, socket.assigns.software_filter) &&
        TimelineHelpers.filter_posts_by_search_query([post], socket.assigns[:search_query]) != []
    end)
  end

  defp post_matches_software_filter?(_post, "all") do
    true
  end

  defp post_matches_software_filter?(post, "local") do
    post.federated != true
  end

  defp post_matches_software_filter?(post, software) when is_binary(software) do
    filter_posts_by_software([post], software) != []
  end

  defp post_matches_software_filter?(_post, _) do
    true
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
      _ -> instance_sw == filter
    end
  end

  defp maybe_prioritize_non_community_posts(posts, socket) do
    if socket.assigns.current_filter in [
         "all",
         "explore",
         "following",
         "home",
         "federated",
         "public"
       ] &&
         socket.assigns.timeline_filter == "all" && socket.assigns.software_filter == "all" do
      {non_community, community} =
        Enum.split_with(posts, fn post -> !PostUtilities.community_post?(post) end)

      non_community ++ community
    else
      posts
    end
  end

  defp convert_remote_replies_to_display_format(remote_replies) do
    remote_replies |> Enum.map(&convert_single_remote_reply/1) |> Enum.filter(&(&1 != nil))
  end

  defp materialize_lemmy_top_comments(post, comments) when is_list(comments) do
    comments |> Enum.map(&materialize_single_lemmy_comment(post, &1)) |> Enum.reject(&is_nil/1)
  end

  defp materialize_lemmy_top_comments(_post, _) do
    []
  end

  defp materialize_single_lemmy_comment(post, %{ap_id: ap_id} = comment) when is_binary(ap_id) do
    case Messaging.get_message_by_activitypub_ref(ap_id) do
      %Elektrine.Messaging.Message{} = existing -> merge_lemmy_comment_counts(existing, comment)
      nil -> create_lemmy_comment_message(post, comment)
    end
  end

  defp materialize_single_lemmy_comment(_post, comment) do
    comment
  end

  defp create_lemmy_comment_message(post, %{ap_id: ap_id, actor_id: actor_uri} = comment)
       when is_binary(actor_uri) and actor_uri != "" do
    with remote_actor when not is_nil(remote_actor) <- resolve_lemmy_comment_actor(actor_uri),
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

  defp create_lemmy_comment_message(_post, comment) do
    comment
  end

  defp resolve_lemmy_comment_actor(actor_uri) when is_binary(actor_uri) and actor_uri != "" do
    case Elektrine.ActivityPub.get_actor_by_uri(actor_uri) do
      nil ->
        case Elektrine.ActivityPub.get_or_fetch_actor(actor_uri) do
          {:ok, actor} -> actor
          _ -> nil
        end

      actor ->
        actor
    end
  end

  defp resolve_lemmy_comment_actor(_), do: nil

  defp merge_lemmy_comment_counts(%Elektrine.Messaging.Message{} = message, comment) do
    %{
      message
      | like_count: max(message.like_count || 0, Map.get(comment, :upvotes, 0)),
        reply_count: max(message.reply_count || 0, Map.get(comment, :child_count, 0))
    }
  end

  defp parse_lemmy_published(nil) do
    DateTime.utc_now()
  end

  defp parse_lemmy_published(published) when is_binary(published) do
    case DateTime.from_iso8601(published) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp parse_lemmy_published(_) do
    DateTime.utc_now()
  end

  defp convert_single_remote_reply(reply_object) when is_map(reply_object) do
    actor_uri = extract_actor_uri(reply_object)

    if is_binary(actor_uri) do
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

      content =
        reply_object["content"] || extract_content_from_map(reply_object["contentMap"]) || ""

      fallback_avatar_url = extract_reply_avatar_fallback(reply_object)
      remote_actor = Elektrine.ActivityPub.get_actor_by_uri(actor_uri)

      remote_actor =
        if remote_actor &&
             is_binary(fallback_avatar_url) &&
             fallback_avatar_url != "" &&
             is_nil(remote_actor.avatar_url) do
          %{remote_actor | avatar_url: fallback_avatar_url}
        else
          remote_actor
        end

      {fallback_author, fallback_domain} = actor_identity_from_uri(actor_uri)

      local_message = Messaging.get_message_by_activitypub_ref(reply_object["id"])

      interaction_id =
        if match?(%Elektrine.Messaging.Message{}, local_message) do
          local_message.id
        else
          reply_object["id"]
        end

      resolved_remote_actor =
        case local_message do
          %Elektrine.Messaging.Message{remote_actor: loaded_remote_actor}
          when is_map(loaded_remote_actor) ->
            case loaded_remote_actor do
              %Ecto.Association.NotLoaded{} -> remote_actor
              _ -> loaded_remote_actor
            end

          _ ->
            remote_actor
        end

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
        remote_actor: resolved_remote_actor,
        remote_actor_id: if(resolved_remote_actor, do: Map.get(resolved_remote_actor, :id)),
        author: fallback_author,
        author_domain: fallback_domain,
        federated: true,
        media_urls: extract_media_urls(reply_object),
        visibility: "public"
      }
    else
      nil
    end
  end

  defp convert_single_remote_reply(_) do
    nil
  end

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

  defp normalize_timeline_view(nil) do
    "all"
  end

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
            ] do
    view
  end

  defp normalize_timeline_view(_) do
    "all"
  end

  defp normalize_composer_intent(intent) when intent in ["post", "note"], do: intent
  defp normalize_composer_intent(_intent), do: nil

  defp maybe_apply_composer_intent(socket, nil, _user), do: socket

  defp maybe_apply_composer_intent(socket, intent, user) do
    socket
    |> assign(:composer_intent, intent)
    |> assign(:show_post_composer, true)
    |> assign(:new_post_visibility, default_post_visibility_for_intent(intent, user))
  end

  defp default_post_visibility_for_intent("note", _user), do: "private"

  defp default_post_visibility_for_intent(_intent, user) do
    (user && user.default_post_visibility) || "public"
  end

  defp default_source_filter(nil), do: "explore"
  defp default_source_filter(_user), do: "home"

  defp normalize_source_filter(nil, user), do: default_source_filter(user)

  defp normalize_source_filter(filter, _user)
       when filter in ["home", "for_you", "explore", "local", "federated", "saved", "rss"] do
    filter
  end

  defp normalize_source_filter("following", _user), do: "home"
  defp normalize_source_filter("all", _user), do: "explore"
  defp normalize_source_filter("public", _user), do: "explore"
  defp normalize_source_filter(_, user), do: default_source_filter(user)

  defp normalize_search_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_search_query(_), do: ""

  defp filter_rss_items_by_query(items, query) when is_list(items) do
    normalized_query = normalize_search_query(query) |> String.downcase()

    if normalized_query == "" do
      items
    else
      Enum.filter(items, fn item ->
        [
          Map.get(item, :title),
          Map.get(item, :content),
          Map.get(item, :feed_title),
          Map.get(item, :url)
        ]
        |> Enum.any?(fn
          value when is_binary(value) ->
            value
            |> String.downcase()
            |> String.contains?(normalized_query)

          _ ->
            false
        end)
      end)
    end
  end

  defp filter_rss_items_by_query(_, _), do: []

  defp extract_actor_uri(%{"attributedTo" => uri}) when is_binary(uri) do
    uri
  end

  defp extract_actor_uri(%{"actor" => uri}) when is_binary(uri) do
    uri
  end

  defp extract_actor_uri(%{"attributedTo" => [uri | _]}) when is_binary(uri) do
    uri
  end

  defp extract_actor_uri(%{"actor" => [uri | _]}) when is_binary(uri) do
    uri
  end

  defp extract_actor_uri(%{"attributedTo" => %{"id" => uri}}) when is_binary(uri) do
    uri
  end

  defp extract_actor_uri(%{"actor" => %{"id" => uri}}) when is_binary(uri) do
    uri
  end

  defp extract_actor_uri(_) do
    nil
  end

  defp actor_identity_from_uri(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host, path: path} ->
        username =
          path
          |> to_string()
          |> String.split("/", trim: true)
          |> List.last()
          |> normalize_actor_segment()

        {username, host}

      _ ->
        {nil, nil}
    end
  end

  defp actor_identity_from_uri(_) do
    {nil, nil}
  end

  defp normalize_actor_segment(segment) when is_binary(segment) do
    segment
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split("#")
    |> hd()
    |> String.split("?")
    |> hd()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_actor_segment(_), do: nil

  defp merge_reply_previews(existing, incoming) do
    (List.wrap(existing) ++ List.wrap(incoming))
    |> Enum.uniq_by(&reply_preview_key/1)
    |> Enum.sort_by(&reply_preview_inserted_at_unix/1, :desc)
    |> Enum.take(3)
    |> Enum.reverse()
  end

  defp reply_preview_key(reply) do
    Map.get(reply, :id) ||
      Map.get(reply, :activitypub_id) ||
      Map.get(reply, :ap_id) ||
      {Map.get(reply, :content), Map.get(reply, :inserted_at)}
  end

  defp reply_preview_inserted_at_unix(reply) do
    case Map.get(reply, :inserted_at) do
      %DateTime{} = dt ->
        DateTime.to_unix(dt)

      %NaiveDateTime{} = naive ->
        naive
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix()

      _ ->
        0
    end
  end

  defp update_posts_for_counts(posts, message_id, counts) when is_list(posts) do
    Enum.map(posts, fn post ->
      cond do
        post.id == message_id ->
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }

        Ecto.assoc_loaded?(post.shared_message) && is_map(post.shared_message) &&
            post.shared_message.id == message_id ->
          %{
            post
            | shared_message: %{
                post.shared_message
                | like_count: counts.like_count,
                  share_count: counts.share_count,
                  reply_count: counts.reply_count
              }
          }

        true ->
          post
      end
    end)
  end

  defp update_posts_for_counts(_posts, _message_id, _counts), do: []

  defp update_reply_previews_for_counts(post_replies, message_id, counts)
       when is_map(post_replies) do
    Map.new(post_replies, fn {post_id, replies} ->
      updated_replies =
        Enum.map(replies, fn reply ->
          if reply.id == message_id do
            %{
              reply
              | like_count: counts.like_count,
                share_count: counts.share_count,
                reply_count: counts.reply_count
            }
          else
            reply
          end
        end)

      {post_id, updated_replies}
    end)
  end

  defp update_reply_previews_for_counts(_post_replies, _message_id, _counts), do: %{}

  defp find_message_post(posts, message_id) when is_list(posts) do
    Enum.find_value(posts, fn post ->
      cond do
        post.id == message_id ->
          post

        Ecto.assoc_loaded?(post.shared_message) && is_map(post.shared_message) &&
            post.shared_message.id == message_id ->
          post.shared_message

        true ->
          nil
      end
    end)
  end

  defp find_message_post(_posts, _message_id), do: nil

  defp clear_post_interaction_state(socket, message_id) do
    interaction_keys =
      [message_id, to_string(message_id), interaction_activitypub_id(socket, message_id)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    updated_interactions =
      Enum.reduce(interaction_keys, socket.assigns[:post_interactions] || %{}, fn key, acc ->
        Map.delete(acc, key)
      end)

    assign(socket, :post_interactions, updated_interactions)
  end

  defp interaction_activitypub_id(socket, message_id) do
    message =
      find_message_post(socket.assigns[:timeline_posts] || [], message_id) ||
        find_message_post(socket.assigns[:base_timeline_posts] || [], message_id) ||
        find_message_reply(socket.assigns[:post_replies] || %{}, message_id)

    case message do
      %{activitypub_id: activitypub_id} when is_binary(activitypub_id) and activitypub_id != "" ->
        activitypub_id

      _ ->
        nil
    end
  end

  defp find_message_reply(post_replies, message_id) when is_map(post_replies) do
    post_replies
    |> Map.values()
    |> List.flatten()
    |> Enum.find(fn reply -> reply.id == message_id end)
  end

  defp find_message_reply(_post_replies, _message_id), do: nil

  defp extract_content_from_map(content_map) when is_map(content_map) do
    content_map |> Map.values() |> Enum.find(&is_binary/1)
  end

  defp extract_content_from_map(_) do
    nil
  end

  defp extract_reply_avatar_fallback(reply_object) do
    mastodon_avatar =
      case Map.get(reply_object, "_mastodon_account") do
        account when is_map(account) -> Map.get(account, :avatar) || Map.get(account, "avatar")
        _ -> nil
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
