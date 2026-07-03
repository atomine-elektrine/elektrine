defmodule ElektrineSocialWeb.RemoteUserLive.Show do
  use ElektrineSocialWeb, :live_view

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.ActivityPub.Instances
  alias Elektrine.Security.SafeExternalURL
  alias ElektrineSocialWeb.RemoteUserLive.ActorLookup
  alias ElektrineSocialWeb.RemoteUserLive.CommunityPostOperations
  alias ElektrineSocialWeb.RemoteUserLive.Counts
  alias ElektrineSocialWeb.RemoteUserLive.FollowOperations
  alias ElektrineSocialWeb.RemoteUserLive.MediaModal
  alias ElektrineSocialWeb.RemoteUserLive.PostInteractionOperations
  alias ElektrineSocialWeb.RemoteUserLive.PostSorting
  alias ElektrineSocialWeb.RemoteUserLive.ReplyOperations
  alias ElektrineSocialWeb.RemoteUserLive.TimelineLoader

  import ElektrineSocialWeb.Components.Platform.ENav
  import ElektrineSocialWeb.Components.Social.TimelinePost, only: [timeline_post: 1]
  import ElektrineWeb.HtmlHelpers
  import Elektrine.Components.Loaders.Skeleton
  import ElektrineWeb.Live.Helpers.PostStateHelpers, only: [get_post_reactions: 1]

  import ElektrineSocialWeb.RemoteUserLive.CommunityPostOperations, only: [error_to_string: 1]

  import ElektrineSocialWeb.RemoteUserLive.Counts,
    only: [maybe_schedule_remote_relationship_counts: 2, resolved_community_stats: 2]

  import ElektrineSocialWeb.RemoteUserLive.PostSorting, only: [get_post_score: 1]

  import ElektrineSocialWeb.RemoteUserLive.PostState,
    only: [
      boosts_by_local_id: 2,
      interaction_state_for_remote_post: 2,
      likes_by_local_id: 2,
      load_post_interactions: 2,
      load_user_saves_for_posts: 2,
      normalize_navigate_post_id: 2,
      parse_non_negative_int: 2,
      post_saved?: 2,
      replies_by_local_id: 2,
      saves_by_local_id: 2
    ]

  import ElektrineSocialWeb.RemoteUserLive.ReactionSurfaces,
    only: [
      normalize_post_reaction_keys: 1,
      post_reaction_surface: 3,
      preview_reply_author: 1,
      reactions_for_entry: 2,
      reply_reaction_surface: 3
    ]

  import ElektrineSocialWeb.RemoteUserLive.TimelineLoader,
    only: [get_local_posts_from_remote_actor: 1]

  @follow_events ~w(toggle_follow)

  @reply_events ~w(show_reply_form cancel_reply update_reply_content submit_reply)

  @post_interaction_events ~w(like_post unlike_post upvote_post unupvote_post downvote_post
    undownvote_post toggle_modal_like boost_post unboost_post quote_post vote_poll
    vote_remote_poll close_quote_modal update_quote_content submit_quote react_to_post
    save_post unsave_post)

  @community_post_events ~w(toggle_create_post update_post_title update_post_content
    open_image_upload close_image_upload validate_community_upload upload_community_images
    clear_pending_images submit_post)

  @impl true
  def mount(params, _session, socket) do
    case ActorLookup.local_profile_redirect_path(params) do
      path when is_binary(path) ->
        {:ok, push_navigate(socket, to: path)}

      nil ->
        mount_remote_profile(params, socket)
    end
  end

  defp mount_remote_profile(params, socket) do
    user = socket.assigns[:current_user]

    # Initialize with loading state
    socket =
      socket
      |> assign(:page_title, "Loading profile...")
      |> assign(:meta_robots, "noindex, nofollow")
      |> assign(:remote_actor, nil)
      |> assign(:is_following, false)
      |> assign(:is_pending, false)
      |> assign(:timeline_posts, [])
      |> assign(:local_posts, [])
      |> assign(:loading, true)
      |> assign(:actor_loading, true)
      |> assign(:error, nil)
      |> assign(:show_reply_form, false)
      |> assign(:reply_to_post, nil)
      |> assign(:reply_content, "")
      |> assign(:post_interactions, %{})
      |> assign(:user_saves, %{})
      |> assign(:show_image_modal, false)
      |> assign(:modal_image_url, nil)
      |> assign(:modal_images, [])
      |> assign(:modal_image_index, 0)
      |> assign(:modal_post, nil)
      |> assign(:post_replies, %{})
      |> assign(:post_reactions, %{})
      |> assign(:show_quote_modal, false)
      |> assign(:quote_target_post, nil)
      |> assign(:quote_target_message_id, nil)
      |> assign(:quote_target_activitypub_id, nil)
      |> assign(:quote_content, "")
      |> assign(:show_create_post, false)
      |> assign(:post_title, "")
      |> assign(:post_content, "")
      |> assign(:sort_by, "hot")
      |> assign(:lemmy_counts, %{})
      |> assign(:mastodon_counts, %{})
      |> assign(:community_stats, %{members: 0, posts: 0})
      |> assign(:show_image_upload_modal, false)
      |> assign(:pending_media_urls, [])
      |> assign(:pending_media_attachments, [])
      |> assign(:pending_media_alt_texts, %{})
      |> assign(:instance_info, nil)

    # Allow media uploads for authenticated users
    socket =
      if user do
        allow_upload(socket, :community_attachments,
          accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav),
          max_entries: 4,
          # 50MB
          max_file_size: 50_000_000
        )
      else
        socket
      end

    case ActorLookup.cached_from_params(params) do
      {:ok, remote_actor} ->
        if connected?(socket) do
          socket = prime_cached_remote_profile(socket, remote_actor)
          send(self(), :load_timeline)
          {:ok, socket}
        else
          {:ok, socket}
        end

      :error ->
        if connected?(socket) do
          send(self(), {:fetch_actor, params})
        end

        {:ok, socket}
    end
  end

  defp setup_actor_socket(socket, remote_actor) do
    {is_following, is_pending} =
      if socket.assigns[:current_user] do
        # Check for accepted follow first
        if Elektrine.Profiles.following_remote_actor_by_identity?(
             socket.assigns.current_user.id,
             remote_actor
           ) do
          {true, false}
        else
          # Check for pending follow
          case Elektrine.Profiles.get_follow_to_remote_actor_by_identity(
                 socket.assigns.current_user.id,
                 remote_actor
               ) do
            %{pending: true} -> {false, true}
            _ -> {false, false}
          end
        end
      else
        {false, false}
      end

    # Subscribe to user's timeline for follow acceptance updates
    if socket.assigns[:current_user] && connected?(socket) do
      Phoenix.PubSub.subscribe(
        Elektrine.PubSub,
        "user:#{socket.assigns.current_user.id}:timeline"
      )
    end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")
    end

    if connected?(socket) && remote_actor.actor_type == "Group" do
      send(self(), :load_community_stats)
    end

    # Load instance metadata (nodeinfo) for display
    instance_info =
      Instances.get_instance_with_metadata(remote_actor.domain, fetch_if_stale: true)

    socket
    |> assign(:page_title, "@#{remote_actor.username}@#{remote_actor.domain}")
    |> assign(:remote_actor, remote_actor)
    |> assign(:is_following, is_following)
    |> assign(:is_pending, is_pending)
    |> assign(:instance_info, instance_info)
    |> assign(
      :community_stats,
      resolved_community_stats(remote_actor, socket.assigns[:community_stats])
    )
    |> assign(:actor_loading, false)
    |> maybe_schedule_remote_relationship_counts(remote_actor)
  end

  defp prime_cached_remote_profile(socket, remote_actor) do
    local_posts = get_local_posts_from_remote_actor(remote_actor)

    post_interactions =
      if socket.assigns[:current_user] && local_posts != [] do
        load_post_interactions(local_posts, socket.assigns.current_user.id)
      else
        socket.assigns.post_interactions
      end

    user_saves =
      if socket.assigns[:current_user] && local_posts != [] do
        load_user_saves_for_posts(local_posts, socket.assigns.current_user.id)
      else
        socket.assigns.user_saves
      end

    post_reactions = normalize_post_reaction_keys(get_post_reactions(local_posts))

    socket
    |> setup_actor_socket(remote_actor)
    |> assign(:local_posts, local_posts)
    |> assign(:post_interactions, post_interactions)
    |> assign(:user_saves, user_saves)
    |> assign(:post_reactions, post_reactions)
    |> assign(:loading, false)
  end

  @impl true
  def handle_info({:fetch_actor, params}, socket) do
    # Fetch actor in a Task to avoid blocking
    task =
      Task.async(fn ->
        case params do
          %{"handle" => handle} ->
            case ActorLookup.parse_remote_handle(handle) do
              {:ok, %{username: username, domain: domain, acct: acct}} ->
                ActorLookup.resolve(username, domain, acct)

              {:error, _reason} ->
                {:error, :invalid_handle}
            end

          _ ->
            {:error, :no_params}
        end
      end)

    case Task.yield(task, 10_000) || Task.shutdown(task) do
      {:ok, {:ok, remote_actor}} ->
        socket = setup_actor_socket(socket, remote_actor)
        send(self(), :load_timeline)
        {:noreply, socket}

      {:ok, {:error, _reason}} ->
        {:noreply,
         socket
         |> assign(:actor_loading, false)
         |> assign(:loading, false)
         |> assign(:error, "Remote user not found")
         |> put_flash(:error, "Remote user not found")}

      nil ->
        {:noreply,
         socket
         |> assign(:actor_loading, false)
         |> assign(:loading, false)
         |> assign(:error, "Remote server took too long to respond")
         |> put_flash(:error, "Remote server took too long to respond")}
    end
  end

  @impl true
  def handle_info(:load_timeline, socket) do
    TimelineLoader.load_timeline(socket)
  end

  def handle_info(:load_community_stats, socket) do
    Counts.load_community_stats(socket)
  end

  def handle_info({:community_stats_loaded, %{} = stats}, socket) do
    Counts.community_stats_loaded(socket, stats)
  end

  def handle_info({:load_remote_relationship_counts, actor_id}, socket) do
    Counts.load_remote_relationship_counts(socket, actor_id)
  end

  def handle_info({:remote_relationship_counts_loaded, actor_id, counts}, socket) do
    Counts.remote_relationship_counts_loaded(socket, actor_id, counts)
  end

  def handle_info(:refresh_remote_counts, socket) do
    Counts.refresh_remote_counts(socket)
  end

  def handle_info(:reload_remote_user_counts, socket) do
    Counts.reload_remote_user_counts(socket)
  end

  def handle_info({:reload_remote_user_community_stats, actor_id, attempt}, socket) do
    Counts.reload_remote_user_community_stats(socket, actor_id, attempt)
  end

  def handle_info(:reload_remote_profile_posts, socket) do
    TimelineLoader.reload_remote_profile_posts(socket)
  end

  def handle_info(:reload_local_posts_after_poll_refresh, socket) do
    TimelineLoader.reload_local_posts_after_poll_refresh(socket)
  end

  def handle_info({:replies_loaded_for_posts, post_replies}, socket) do
    TimelineLoader.replies_loaded_for_posts(socket, post_replies)
  end

  def handle_info({:refresh_post_replies, post_refs, attempt}, socket) do
    TimelineLoader.refresh_post_replies(socket, post_refs, attempt)
  end

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    TimelineLoader.post_counts_updated(socket, message_id, counts)
  end

  # Handle follow acceptance - update button state without refresh
  def handle_info({:follow_accepted, remote_actor_id}, socket) do
    FollowOperations.follow_accepted(socket, remote_actor_id)
  end

  def handle_info(_msg, socket) do
    # Ignore other PubSub messages (presence, etc.)
    {:noreply, socket}
  end

  @impl true
  def handle_event(event, params, socket) when event in @follow_events do
    FollowOperations.handle_event(event, params, socket)
  end

  def handle_event("change_sort", %{"sort" => sort_by}, socket) do
    {:noreply, assign(socket, :sort_by, sort_by)}
  end

  def handle_event("open_external_post", %{"url" => url}, socket) do
    {:noreply, redirect_to_external_url(socket, url)}
  end

  def handle_event(event, params, socket) when event in @reply_events do
    ReplyOperations.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @post_interaction_events do
    PostInteractionOperations.handle_event(event, params, socket)
  end

  def handle_event("record_dwell_time", params, socket) do
    if user = socket.assigns[:current_user] do
      record_remote_profile_dwell_view(user.id, params)
    end

    {:noreply, socket}
  end

  def handle_event("record_dwell_times", params, socket) do
    if user = socket.assigns[:current_user] do
      params
      |> Map.get("views", [])
      |> case do
        views when is_list(views) ->
          Enum.each(views, &record_remote_profile_dwell_view(user.id, &1))

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  def handle_event("record_dismissal", params, socket) do
    if user = socket.assigns[:current_user] do
      post_id = Map.get(params, "post_id")
      type = Map.get(params, "type")
      dwell_time_ms = Map.get(params, "dwell_time_ms")

      if is_binary(post_id) and post_id != "" and is_binary(type) and type != "" do
        Elektrine.Social.Recommendations.record_dismissal(user.id, post_id, type, dwell_time_ms)
      end
    end

    {:noreply, socket}
  end

  def handle_event(
        "open_image_modal",
        %{"images" => images_json, "index" => index} = params,
        socket
      ) do
    with {:ok, decoded_images} <- Jason.decode(images_json),
         images when images != [] <- Enum.filter(decoded_images, &is_binary/1) do
      index_int = parse_non_negative_int(index, 0) |> min(length(images) - 1)
      url = params["url"] || Enum.at(images, index_int, List.first(images))
      post_id = params["post_id"]

      # Find the post and attach remote_actor for the modal display
      modal_post =
        if post_id do
          # Try to find in local_posts first
          local_post =
            Enum.find(socket.assigns.local_posts, fn p ->
              p.activitypub_id == post_id || to_string(p.id) == post_id
            end)

          if local_post do
            # Local post - attach remote_actor
            %{local_post | remote_actor: socket.assigns.remote_actor}
          else
            # Create a pseudo-post for remote actor context with activitypub_id for navigation
            %{
              remote_actor: socket.assigns.remote_actor,
              content: nil,
              inserted_at: DateTime.utc_now(),
              activitypub_id: post_id
            }
          end
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
    else
      _ -> {:noreply, socket}
    end
  end

  # close_image_modal / next_image / prev_image only touch the canonical modal-state
  # assigns, so delegate to the shared image-modal handlers.
  def handle_event(event, params, socket)
      when event in ["close_image_modal", "next_image", "prev_image"] do
    ElektrineSocialWeb.TimelineLive.Operations.ImageOperations.handle_event(event, params, socket)
  end

  def handle_event("next_media_post", _params, socket) do
    MediaModal.navigate_to_media_post(socket, :next)
  end

  def handle_event("prev_media_post", _params, socket) do
    MediaModal.navigate_to_media_post(socket, :prev)
  end

  def handle_event("navigate_to_post", %{"post_id" => post_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, post_id)
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, navigate_id)}
  end

  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, navigate_id)}
  end

  def handle_event("navigate_to_post", %{"message_id" => message_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, message_id)
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, navigate_id)}
  end

  def handle_event("navigate_to_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, navigate_id)}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" and url != "#" do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("navigate_to_embedded_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket)
      when is_binary(handle) and handle != "" do
    ElektrineWeb.ProfileNavigation.navigate(socket, %{"handle" => handle})
  end

  def handle_event("navigate_to_profile", %{"username" => username}, socket)
      when is_binary(username) and username != "" do
    ElektrineWeb.ProfileNavigation.navigate(socket, %{"username" => username})
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("load-more", _params, socket) do
    # Infinite scroll triggered - could fetch more posts from remote
    # Remote profiles currently display a fixed number of posts.
    # Could implement pagination here if needed
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @community_post_events do
    CommunityPostOperations.handle_event(event, params, socket)
  end

  # Sorting functions for Lemmy-style post sorting (called from the template)
  defdelegate sort_posts(posts, sort_by), to: PostSorting

  defp normalize_remote_post_title(post) when is_map(post) do
    [post["name"], post["title"]]
    |> Enum.find_value(fn
      title when is_binary(title) ->
        case String.trim(title) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end)
  end

  defp normalize_remote_post_title(_), do: nil

  # Helper functions - delegating to shared APHelpers module

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
  defp format_join_date(date), do: APHelpers.format_join_date(date)
  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)
  defp get_follower_count(meta), do: APHelpers.get_follower_count(meta)
  defp get_following_count(meta), do: APHelpers.get_following_count(meta)
  defp get_status_count(meta), do: APHelpers.get_status_count(meta)

  defp record_remote_profile_dwell_view(user_id, params)
       when is_integer(user_id) and is_map(params) do
    case Map.get(params, "post_id") do
      post_id when is_binary(post_id) and post_id != "" ->
        attrs = %{
          dwell_time_ms: Map.get(params, "dwell_time_ms"),
          scroll_depth: Map.get(params, "scroll_depth"),
          expanded: Map.get(params, "expanded") || false,
          source: Map.get(params, "source") || "remote_profile"
        }

        Elektrine.Social.Recommendations.record_view_with_dwell(user_id, post_id, attrs)

      _ ->
        :ok
    end
  end

  defp record_remote_profile_dwell_view(_, _), do: :ok

  defp redirect_to_external_url(socket, url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> redirect(socket, external: safe_url)
      {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
    end
  end
end
