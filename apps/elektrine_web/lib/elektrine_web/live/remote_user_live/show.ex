defmodule ElektrineWeb.RemoteUserLive.Show do
  use ElektrineWeb, :live_view

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.ActivityPub.Instances
  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.{Repo, Social}
  alias ElektrineWeb.Live.PostInteractions
  alias ElektrineWeb.RemotePostLive.SurfaceHelpers

  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.TimelinePost, only: [timeline_post: 1]
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.Loaders.Skeleton
  import ElektrineWeb.Live.Helpers.PostStateHelpers, only: [get_post_reactions: 1]

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns[:current_user]

    # Initialize with loading state
    socket =
      socket
      |> assign(:page_title, "Loading profile...")
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

    # Try to get cached actor first (fast path)
    remote_actor = get_cached_actor(params)

    if remote_actor do
      # Actor was cached, set up socket and show local posts immediately
      socket = setup_actor_socket(socket, remote_actor)

      # Load local posts synchronously to prevent flicker (fast DB query)
      local_posts = get_local_posts_from_remote_actor(remote_actor)
      socket = assign(socket, :local_posts, local_posts)

      socket =
        assign(
          socket,
          :post_reactions,
          normalize_post_reaction_keys(get_post_reactions(local_posts))
        )

      socket = assign(socket, :loading, Enum.empty?(local_posts))

      # Load interactions for local posts
      socket =
        if socket.assigns[:current_user] && local_posts != [] do
          all_posts_for_interactions =
            Enum.map(local_posts, fn post ->
              %{"id" => post.activitypub_id}
            end)

          post_interactions =
            load_post_interactions(all_posts_for_interactions, socket.assigns.current_user.id)

          user_saves = load_user_saves_for_posts(local_posts, socket.assigns.current_user.id)

          socket
          |> assign(:post_interactions, post_interactions)
          |> assign(:user_saves, user_saves)
        else
          socket
        end

      # Fetch remote posts in background after connection
      if connected?(socket), do: send(self(), :load_timeline)
      {:ok, socket}
    else
      # Need to fetch actor - defer to handle_info
      if connected?(socket) do
        send(self(), {:fetch_actor, params})
      end

      {:ok, socket}
    end
  end

  # Fast path: check if actor is already cached locally
  defp get_cached_actor(params) do
    case params do
      %{"handle" => handle} ->
        case String.split(handle, "@", parts: 2) do
          [username, domain] ->
            username = String.trim_leading(username, "!")
            ActivityPub.get_actor_by_username_and_domain(username, domain)

          _ ->
            nil
        end

      %{"id" => remote_actor_id} ->
        Repo.get(Elektrine.ActivityPub.Actor, String.to_integer(remote_actor_id))

      _ ->
        nil
    end
  end

  defp setup_actor_socket(socket, remote_actor) do
    {is_following, is_pending} =
      if socket.assigns[:current_user] do
        # Check for accepted follow first
        if Elektrine.Profiles.following_remote_actor?(
             socket.assigns.current_user.id,
             remote_actor.id
           ) do
          {true, false}
        else
          # Check for pending follow
          case Elektrine.Profiles.get_follow_to_remote_actor(
                 socket.assigns.current_user.id,
                 remote_actor.id
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
    |> assign(:community_stats, initial_community_stats(remote_actor))
    |> assign(:actor_loading, false)
  end

  @impl true
  def handle_info({:fetch_actor, params}, socket) do
    # Fetch actor in a Task to avoid blocking
    task =
      Task.async(fn ->
        case params do
          %{"handle" => handle} ->
            case String.split(handle, "@", parts: 2) do
              [username, domain] ->
                username = String.trim_leading(username, "!")
                acct = "#{username}@#{domain}"

                case ActivityPub.Fetcher.webfinger_lookup(acct) do
                  {:ok, actor_uri} ->
                    case ActivityPub.get_or_fetch_actor(actor_uri) do
                      {:ok, actor} -> {:ok, actor}
                      error -> error
                    end

                  error ->
                    error
                end

              _ ->
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
    remote_actor = socket.assigns.remote_actor

    # Check for nil actor (can happen if fetch failed)
    if is_nil(remote_actor) do
      {:noreply, assign(socket, :loading, false)}
    else
      is_lemmy = remote_actor.actor_type == "Group"

      # Use already-loaded local posts if available, otherwise load them now
      local_posts =
        if socket.assigns.local_posts && socket.assigns.local_posts != [] do
          socket.assigns.local_posts
        else
          get_local_posts_from_remote_actor(remote_actor)
        end

      # Load interaction state for local posts if not already loaded
      post_interactions =
        if socket.assigns[:current_user] && local_posts != [] &&
             map_size(socket.assigns.post_interactions) == 0 do
          all_posts_for_interactions =
            Enum.map(local_posts, fn post ->
              %{"id" => post.activitypub_id}
            end)

          load_post_interactions(all_posts_for_interactions, socket.assigns.current_user.id)
        else
          socket.assigns.post_interactions
        end

      user_saves =
        if socket.assigns[:current_user] && local_posts != [] &&
             map_size(socket.assigns.user_saves) == 0 do
          load_user_saves_for_posts(local_posts, socket.assigns.current_user.id)
        else
          socket.assigns.user_saves
        end

      post_reactions = normalize_post_reaction_keys(get_post_reactions(local_posts))

      # Show local posts immediately
      socket =
        socket
        |> assign(:local_posts, local_posts)
        |> assign(:post_interactions, post_interactions)
        |> assign(:user_saves, user_saves)
        |> assign(:post_reactions, post_reactions)
        |> assign(:loading, false)

      # PHASE 2: Kick off remote fetches in background (non-blocking)
      pid = self()
      local_ap_ids = local_posts |> Enum.map(& &1.activitypub_id) |> MapSet.new()

      # Load replies/comments for posts we already have cached.
      schedule_replies_fetch(local_posts, pid)

      # Fetch outbox in background
      Task.start(fn ->
        outbox_posts =
          case ActivityPub.fetch_remote_user_timeline(remote_actor.id, limit: 20) do
            {:ok, posts} -> posts
            {:error, _} -> []
          end

        send(pid, {:outbox_loaded, outbox_posts, local_ap_ids, remote_actor})
      end)

      # Fetch Lemmy counts in background
      if is_lemmy && local_posts != [] do
        Task.start(fn ->
          lemmy_counts =
            local_posts
            |> Enum.map(& &1.activitypub_id)
            |> Enum.filter(& &1)
            |> Task.async_stream(
              fn ap_id ->
                case Elektrine.ActivityPub.LemmyApi.fetch_post_counts(ap_id) do
                  %{score: _} = counts -> {ap_id, counts}
                  _ -> nil
                end
              end,
              max_concurrency: 10,
              timeout: 8_000,
              on_timeout: :kill_task
            )
            |> Enum.reduce(%{}, fn
              {:ok, {ap_id, counts}}, acc when not is_nil(counts) -> Map.put(acc, ap_id, counts)
              _, acc -> acc
            end)

          send(pid, {:lemmy_counts_loaded, lemmy_counts})
        end)
      end

      {:noreply, socket}
    end
  end

  def handle_info(:load_community_stats, socket) do
    case socket.assigns.remote_actor do
      %{actor_type: "Group"} = remote_actor ->
        pid = self()

        Task.start(fn ->
          stats = fetch_group_stats(remote_actor)
          send(pid, {:community_stats_loaded, stats})
        end)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:community_stats_loaded, %{} = stats}, socket) do
    current = socket.assigns[:community_stats] || %{members: 0, posts: 0}

    merged_stats = %{
      members: max(current[:members] || 0, stats[:members] || 0),
      posts: max(current[:posts] || 0, stats[:posts] || 0)
    }

    {:noreply, assign(socket, :community_stats, merged_stats)}
  end

  def handle_info({:outbox_loaded, outbox_posts, local_ap_ids, remote_actor}, socket) do
    # Filter to unique posts
    unique_outbox_posts =
      outbox_posts
      |> Enum.reject(fn post -> MapSet.member?(local_ap_ids, post["id"]) end)

    if Enum.empty?(unique_outbox_posts) do
      {:noreply, socket}
    else
      # Store outbox posts locally
      stored_posts = store_outbox_posts(unique_outbox_posts, remote_actor)

      # Sync counts for all outbox posts (async, non-blocking)
      Task.start(fn ->
        Enum.each(outbox_posts, &Elektrine.Messaging.Messages.sync_remote_counts/1)
      end)

      # Proactively fetch and store replies for posts with reply collections (Akkoma-style)
      Task.start(fn ->
        outbox_posts
        |> Enum.filter(fn post -> post["replies"] != nil end)
        # Limit to avoid overwhelming
        |> Enum.take(10)
        |> Enum.each(fn post ->
          Elektrine.ActivityPub.RepliesFetcher.fetch_and_store_replies(post, max_replies: 20)
        end)
      end)

      # Merge with existing local posts
      current_local_posts = socket.assigns.local_posts

      all_local_posts =
        (stored_posts ++ current_local_posts)
        |> Enum.uniq_by(& &1.activitypub_id)

      # Update interactions for new posts
      new_interactions =
        if socket.assigns[:current_user] && stored_posts != [] do
          new_posts_for_interactions =
            Enum.map(stored_posts, fn post ->
              %{"id" => post.activitypub_id}
            end)

          load_post_interactions(new_posts_for_interactions, socket.assigns.current_user.id)
        else
          %{}
        end

      post_interactions = Map.merge(socket.assigns.post_interactions, new_interactions)

      new_user_saves =
        if socket.assigns[:current_user] && stored_posts != [] do
          load_user_saves_for_posts(stored_posts, socket.assigns.current_user.id)
        else
          %{}
        end

      user_saves = Map.merge(socket.assigns.user_saves, new_user_saves)
      new_post_reactions = normalize_post_reaction_keys(get_post_reactions(stored_posts))
      post_reactions = Map.merge(socket.assigns.post_reactions || %{}, new_post_reactions)

      # Load replies/comments for newly discovered outbox posts.
      schedule_replies_fetch(unique_outbox_posts, self())

      {:noreply,
       socket
       |> assign(:local_posts, all_local_posts)
       |> assign(:post_interactions, post_interactions)
       |> assign(:user_saves, user_saves)
       |> assign(:post_reactions, post_reactions)}
    end
  end

  def handle_info({:lemmy_counts_loaded, lemmy_counts}, socket) do
    # Schedule periodic refresh every 60 seconds
    Process.send_after(self(), :refresh_remote_counts, 60_000)
    {:noreply, assign(socket, :lemmy_counts, lemmy_counts)}
  end

  def handle_info(:refresh_remote_counts, socket) do
    posts = socket.assigns.local_posts || []

    if posts != [] do
      # Fetch counts using appropriate API based on post type
      lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_posts_counts(posts)
      mastodon_counts = Elektrine.ActivityPub.MastodonApi.fetch_statuses_counts(posts)

      # Update local database with fresh counts (async)
      Task.start(fn ->
        update_posts_with_api_counts(posts, lemmy_counts, mastodon_counts)
      end)

      Process.send_after(self(), :refresh_remote_counts, 60_000)

      {:noreply,
       socket
       |> assign(:lemmy_counts, lemmy_counts)
       |> assign(:mastodon_counts, mastodon_counts)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:replies_loaded_for_posts, post_replies}, socket) do
    current_replies = socket.assigns.post_replies || %{}
    {:noreply, assign(socket, :post_replies, Map.merge(current_replies, post_replies))}
  end

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    updated_local_posts =
      Enum.map(socket.assigns.local_posts || [], fn post ->
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

    updated_lemmy_counts =
      case Enum.find(updated_local_posts, &(&1.id == message_id)) do
        %{activitypub_id: activitypub_id} when is_binary(activitypub_id) ->
          existing = Map.get(socket.assigns.lemmy_counts || %{}, activitypub_id, %{})

          Map.put(
            socket.assigns.lemmy_counts || %{},
            activitypub_id,
            existing
            |> Map.put(:score, counts.like_count)
            |> Map.put(:comments, counts.reply_count)
          )

        _ ->
          socket.assigns.lemmy_counts || %{}
      end

    updated_mastodon_counts =
      case Enum.find(updated_local_posts, &(&1.id == message_id)) do
        %{activitypub_id: activitypub_id} when is_binary(activitypub_id) ->
          existing = Map.get(socket.assigns.mastodon_counts || %{}, activitypub_id, %{})

          Map.put(
            socket.assigns.mastodon_counts || %{},
            activitypub_id,
            existing
            |> Map.put(:favourites_count, counts.like_count)
            |> Map.put(:reblogs_count, counts.share_count)
            |> Map.put(:replies_count, counts.reply_count)
          )

        _ ->
          socket.assigns.mastodon_counts || %{}
      end

    {:noreply,
     socket
     |> assign(:local_posts, updated_local_posts)
     |> assign(:modal_post, updated_modal_post)
     |> assign(:lemmy_counts, updated_lemmy_counts)
     |> assign(:mastodon_counts, updated_mastodon_counts)}
  end

  # Handle follow acceptance - update button state without refresh
  def handle_info({:follow_accepted, remote_actor_id}, socket) do
    # Only update if this is the actor we're viewing
    if socket.assigns.remote_actor && socket.assigns.remote_actor.id == remote_actor_id do
      {:noreply,
       socket
       |> assign(:is_following, true)
       |> assign(:is_pending, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    # Ignore other PubSub messages (presence, etc.)
    {:noreply, socket}
  end

  defp schedule_replies_fetch(posts, liveview_pid) when is_list(posts) do
    candidates =
      posts
      |> Enum.filter(&reply_fetch_candidate?/1)
      |> Enum.take(10)

    if candidates != [] do
      Task.start(fn ->
        post_replies =
          candidates
          |> Task.async_stream(
            &fetch_replies_for_post/1,
            max_concurrency: 5,
            timeout: 12_000,
            on_timeout: :kill_task
          )
          |> Enum.reduce(%{}, fn
            {:ok, {post_id, replies}}, acc
            when is_binary(post_id) and is_list(replies) and replies != [] ->
              Map.put(acc, post_id, replies)

            _, acc ->
              acc
          end)

        if map_size(post_replies) > 0 do
          send(liveview_pid, {:replies_loaded_for_posts, post_replies})
        end
      end)
    end
  end

  defp schedule_replies_fetch(_, _), do: :ok

  defp reply_fetch_candidate?(%{"id" => id} = post) when is_binary(id) do
    has_collection_ref?(post["replies"]) ||
      has_collection_ref?(post["comments"]) ||
      parse_non_negative_count(post["repliesCount"]) > 0 ||
      extract_count_from_collection(post["replies"]) > 0 ||
      extract_count_from_collection(post["comments"]) > 0
  end

  defp reply_fetch_candidate?(%{activitypub_id: id} = post) when is_binary(id) do
    metadata = post.media_metadata || %{}

    cached_reply_count(post) > 0 ||
      has_collection_ref?(metadata["replies"]) ||
      has_collection_ref?(metadata["comments"])
  end

  defp reply_fetch_candidate?(_), do: false

  defp fetch_replies_for_post(%{"id" => post_id} = post) do
    case ActivityPub.fetch_remote_post_replies(post, limit: 20) do
      {:ok, replies} -> {post_id, replies}
      _ -> {post_id, []}
    end
  end

  defp fetch_replies_for_post(%{activitypub_id: post_id} = post) when is_binary(post_id) do
    metadata = post.media_metadata || %{}
    post_url = post.activitypub_url || post_id
    is_community_post = community_post_url?(post_id) || community_post_url?(post_url)

    post_object = %{
      "id" => post_id,
      "url" => post_url,
      "type" => if(is_community_post, do: "Page", else: "Note"),
      "replies" => metadata["replies"],
      "comments" => metadata["comments"],
      "repliesCount" => cached_reply_count(post)
    }

    case ActivityPub.fetch_remote_post_replies(post_object, limit: 20) do
      {:ok, replies} -> {post_id, replies}
      _ -> {post_id, []}
    end
  end

  defp fetch_replies_for_post(_), do: {nil, []}

  defp has_collection_ref?(value) when is_binary(value), do: true

  defp has_collection_ref?(value) when is_map(value) do
    is_binary(value["id"]) || is_binary(value["first"]) || is_list(value["items"]) ||
      is_list(value["orderedItems"]) ||
      parse_non_negative_count(value["totalItems"]) > 0
  end

  defp has_collection_ref?(_), do: false

  defp cached_reply_count(post) do
    metadata = post.media_metadata || %{}

    [
      parse_non_negative_count(post.reply_count),
      parse_non_negative_count(metadata["original_reply_count"]),
      parse_non_negative_count(metadata["reply_count"]),
      parse_non_negative_count(metadata["replies_count"]),
      extract_count_from_collection(metadata["replies"]),
      extract_count_from_collection(metadata["comments"])
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp community_post_url?(url) when is_binary(url) do
    LemmyApi.community_post_url?(url)
  end

  defp community_post_url?(_), do: false

  defp update_posts_with_api_counts(posts, lemmy_counts, mastodon_counts) do
    import Ecto.Query

    Enum.each(posts, fn post ->
      ap_id = post.activitypub_id

      updates =
        cond do
          # Lemmy counts
          counts = Map.get(lemmy_counts, ap_id) ->
            [
              like_count: max(counts.score, post.like_count || 0),
              reply_count: max(counts.comments, post.reply_count || 0)
            ]

          # Mastodon counts
          counts = Map.get(mastodon_counts, ap_id) ->
            [
              like_count: max(counts.favourites_count, post.like_count || 0),
              reply_count: max(counts.replies_count, post.reply_count || 0),
              share_count: max(counts.reblogs_count, post.share_count || 0)
            ]

          true ->
            []
        end

      if updates != [] do
        Elektrine.Repo.update_all(
          from(m in Elektrine.Messaging.Message, where: m.id == ^post.id),
          set: updates ++ [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )
      end
    end)
  end

  defp get_local_posts_from_remote_actor(remote_actor) do
    import Ecto.Query
    preloads = MessagingMessages.timeline_post_preloads()

    # For Group actors (Lemmy communities), query by community_actor_uri in media_metadata
    # These posts may not have a conversation_id (federated community posts)
    # For Person actors, query by remote_actor_id
    if remote_actor.actor_type == "Group" do
      # For Lemmy communities: posts are "Page" type, comments are "Note" type
      # Filter to only show Page type (or null for older posts without type stored)
      # Also filter out Lemmy comment URLs which contain "/comment/"
      Repo.all(
        from(m in Elektrine.Messaging.Message,
          left_join: c in Elektrine.Messaging.Conversation,
          on: c.id == m.conversation_id,
          where: fragment("?->>'community_actor_uri' = ?", m.media_metadata, ^remote_actor.uri),
          where: is_nil(c.id) or c.type == "timeline",
          where: m.visibility == "public" or is_nil(m.visibility),
          where: is_nil(m.deleted_at),
          where: is_nil(m.reply_to_id),
          # Filter out comments: must not have inReplyTo
          where:
            fragment("?->>'inReplyTo' IS NULL OR ? IS NULL", m.media_metadata, m.media_metadata),
          # For Lemmy: must be Page/Article type (not Note), OR no type stored but not a comment URL
          where:
            fragment(
              "(?->>'type' = 'Page' OR ?->>'type' = 'Article') OR (?->>'type' IS NULL AND ? NOT LIKE '%/comment/%')",
              m.media_metadata,
              m.media_metadata,
              m.media_metadata,
              m.activitypub_id
            ),
          order_by: [desc: m.inserted_at],
          limit: 50,
          preload: ^preloads
        )
      )
    else
      # For Person actors, query by remote_actor_id
      # Use left_join since federated posts might not have a conversation
      # Include replies - they'll be displayed with a "replying to" indicator
      Repo.all(
        from(m in Elektrine.Messaging.Message,
          left_join: c in Elektrine.Messaging.Conversation,
          on: c.id == m.conversation_id,
          where: m.remote_actor_id == ^remote_actor.id,
          where: is_nil(c.id) or c.type == "timeline",
          where: m.visibility == "public" or is_nil(m.visibility),
          where: is_nil(m.deleted_at),
          order_by: [desc: m.inserted_at],
          limit: 50,
          preload: ^preloads
        )
      )
    end
  end

  defp store_outbox_posts(outbox_posts, remote_actor) do
    alias Elektrine.Messaging

    outbox_posts
    |> Enum.map(fn post ->
      case post["id"] do
        activitypub_id when is_binary(activitypub_id) and activitypub_id != "" ->
          case Messaging.get_message_by_activitypub_id(activitypub_id) do
            nil ->
              create_outbox_post(post, remote_actor)

            existing ->
              refresh_existing_outbox_post(existing, post, remote_actor)
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp create_outbox_post(post, remote_actor) do
    alias Elektrine.Messaging

    # Get or fetch the author actor
    author_uri = post["attributedTo"] || remote_actor.uri

    author_actor =
      case ActivityPub.get_or_fetch_actor(author_uri) do
        {:ok, actor} -> actor
        _ -> nil
      end

    if author_actor do
      title = normalize_remote_post_title(post)
      content = post["content"] || title || ""

      # Extract media
      {media_urls, alt_texts} = extract_media_from_post(post)

      # Extract like/reply/share counts from ActivityPub collections
      like_count = extract_count_from_collection(post["likes"])

      reply_count =
        [
          extract_count_from_collection(post["replies"]),
          extract_count_from_collection(post["comments"]),
          parse_non_negative_count(post["repliesCount"])
        ]
        |> Enum.max(fn -> 0 end)

      share_count = extract_count_from_collection(post["shares"])

      metadata = build_outbox_metadata(post, alt_texts, remote_actor)

      # Parse the published date
      inserted_at =
        case post["published"] do
          date when is_binary(date) ->
            case DateTime.from_iso8601(date) do
              {:ok, dt, _} -> DateTime.to_naive(dt)
              _ -> NaiveDateTime.utc_now()
            end

          _ ->
            NaiveDateTime.utc_now()
        end

      # Create the message
      case Messaging.create_federated_message(%{
             content: content,
             title: title,
             visibility: "public",
             activitypub_id: post["id"],
             activitypub_url: post["url"] || post["id"],
             federated: true,
             remote_actor_id: author_actor.id,
             media_urls: media_urls,
             media_metadata: metadata,
             inserted_at: inserted_at,
             like_count: like_count,
             reply_count: reply_count,
             share_count: share_count
           }) do
        {:ok, message} ->
          # Spawn background task to fetch like/reply counts from collection URLs
          spawn_count_fetcher(message.id, post)
          # Preload associations for display
          Repo.preload(message, MessagingMessages.timeline_post_preloads())

        {:error, _} ->
          nil
      end
    else
      nil
    end
  end

  defp refresh_existing_outbox_post(existing, post, remote_actor) do
    title = normalize_remote_post_title(post)
    content = post["content"] || title || ""
    {media_urls, alt_texts} = extract_media_from_post(post)

    metadata =
      build_outbox_metadata(post, alt_texts, remote_actor, existing.media_metadata || %{})

    like_count = extract_count_from_collection(post["likes"])

    reply_count =
      [
        extract_count_from_collection(post["replies"]),
        extract_count_from_collection(post["comments"]),
        parse_non_negative_count(post["repliesCount"])
      ]
      |> Enum.max(fn -> 0 end)

    share_count = extract_count_from_collection(post["shares"])

    updates =
      %{}
      |> maybe_put_if_blank(:title, existing.title, title)
      |> maybe_put_if_blank(:content, existing.content, content)
      |> maybe_put_if_empty_list(:media_urls, existing.media_urls || [], media_urls)
      |> maybe_put_if_blank(:activitypub_url, existing.activitypub_url, post["url"] || post["id"])
      |> maybe_put_if_changed(:media_metadata, existing.media_metadata || %{}, metadata)
      |> maybe_put_if_greater(:like_count, existing.like_count || 0, like_count)
      |> maybe_put_if_greater(:reply_count, existing.reply_count || 0, reply_count)
      |> maybe_put_if_greater(:share_count, existing.share_count || 0, share_count)

    if map_size(updates) > 0 do
      case existing
           |> Ecto.Changeset.change(updates)
           |> Repo.update() do
        {:ok, message} ->
          Repo.preload(message, MessagingMessages.timeline_post_preloads())

        {:error, _} ->
          nil
      end
    else
      nil
    end
  end

  defp spawn_count_fetcher(message_id, post) do
    Task.start(fn ->
      # Fetch like count from collection URL if it's a URL string
      like_count = fetch_collection_count(post["likes"])

      reply_count =
        [
          fetch_collection_count(post["replies"]),
          fetch_collection_count(post["comments"]),
          parse_non_negative_count(post["repliesCount"])
        ]
        |> Enum.max(fn -> 0 end)

      # Update the message with fetched counts if any are non-zero
      if like_count > 0 || reply_count > 0 do
        import Ecto.Query

        from(m in Elektrine.Messaging.Message,
          where: m.id == ^message_id,
          update: [
            set: [
              like_count: fragment("GREATEST(like_count, ?)", ^like_count),
              reply_count: fragment("GREATEST(reply_count, ?)", ^reply_count)
            ]
          ]
        )
        |> Repo.update_all([])
      end
    end)
  end

  defp fetch_collection_count(nil), do: 0

  defp fetch_collection_count(url) when is_binary(url) do
    case Elektrine.ActivityPub.CollectionFetcher.fetch_collection_count(url) do
      {:ok, count} -> parse_non_negative_count(count)
      _ -> 0
    end
  end

  defp fetch_collection_count(collection) when is_map(collection) do
    case Elektrine.ActivityPub.CollectionFetcher.fetch_collection_count(collection) do
      {:ok, count} -> parse_non_negative_count(count)
      _ -> 0
    end
  end

  defp fetch_collection_count(_), do: 0

  defp maybe_put_community_actor_uri(metadata, %{actor_type: "Group", uri: uri})
       when is_map(metadata) and is_binary(uri) do
    Map.put(metadata, "community_actor_uri", uri)
  end

  defp maybe_put_community_actor_uri(metadata, _remote_actor) when is_map(metadata), do: metadata

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

  defp build_outbox_metadata(post, alt_texts, remote_actor, base_metadata \\ %{})
       when is_map(base_metadata) do
    base_metadata
    |> maybe_put_metadata_field("type", post["type"])
    |> maybe_put_metadata_field("url", post["url"])
    |> maybe_put_metadata_field("sensitive", post["sensitive"])
    |> maybe_put_metadata_field("quoteUrl", post["quoteUrl"] || post["_misskey_quote"])
    |> maybe_put_metadata_field("replies", post["replies"])
    |> maybe_put_metadata_field("comments", post["comments"])
    |> maybe_put_metadata_field("likes", post["likes"])
    |> maybe_put_metadata_field("shares", post["shares"])
    |> maybe_put_community_actor_uri(remote_actor)
    |> Map.merge(alt_texts)
  end

  defp maybe_put_metadata_field(metadata, _key, nil), do: metadata

  defp maybe_put_metadata_field(metadata, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      metadata
    else
      Map.put(metadata, key, value)
    end
  end

  defp maybe_put_metadata_field(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_if_blank(updates, field, current, candidate) do
    current_blank? =
      case current do
        value when is_binary(value) -> String.trim(value) == ""
        _ -> true
      end

    candidate_present? =
      case candidate do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end

    if current_blank? && candidate_present? do
      Map.put(updates, field, candidate)
    else
      updates
    end
  end

  defp maybe_put_if_empty_list(updates, _field, current, _candidate)
       when is_list(current) and current != [] do
    updates
  end

  defp maybe_put_if_empty_list(updates, field, _current, candidate)
       when is_list(candidate) and candidate != [] do
    Map.put(updates, field, candidate)
  end

  defp maybe_put_if_empty_list(updates, _field, _current, _candidate), do: updates

  defp maybe_put_if_changed(updates, field, current, candidate) do
    if candidate != current do
      Map.put(updates, field, candidate)
    else
      updates
    end
  end

  defp maybe_put_if_greater(updates, field, current, candidate)
       when is_integer(candidate) and candidate > current do
    Map.put(updates, field, candidate)
  end

  defp maybe_put_if_greater(updates, _field, _current, _candidate), do: updates

  defp extract_media_from_post(post) do
    attachments = post["attachment"] || post["image"] || []
    attachments = if is_list(attachments), do: attachments, else: [attachments]

    {urls, alt_texts} =
      Enum.reduce(attachments, {[], %{}}, fn attachment, {urls_acc, alt_acc} ->
        url =
          cond do
            is_binary(attachment) -> attachment
            is_map(attachment) && is_binary(attachment["url"]) -> attachment["url"]
            is_map(attachment) && is_map(attachment["url"]) -> attachment["url"]["href"]
            true -> nil
          end

        alt = if is_map(attachment), do: attachment["name"] || attachment["summary"], else: nil

        if url do
          new_alts = if alt, do: Map.put(alt_acc, url, alt), else: alt_acc
          {urls_acc ++ [url], new_alts}
        else
          {urls_acc, alt_acc}
        end
      end)

    {urls, %{"alt_texts" => alt_texts}}
  end

  defp extract_count_from_collection(nil), do: 0

  defp extract_count_from_collection(collection) when is_map(collection) do
    parse_non_negative_count(collection["totalItems"])
  end

  defp extract_count_from_collection(collection) when is_integer(collection), do: collection

  defp extract_count_from_collection(collection) when is_binary(collection),
    do: parse_non_negative_count(collection)

  defp extract_count_from_collection(_), do: 0

  defp parse_non_negative_count(value) when is_integer(value), do: max(value, 0)

  defp parse_non_negative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp parse_non_negative_count(_), do: 0

  @impl true
  def handle_event("toggle_follow", _params, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    else
      remote_actor_id = socket.assigns.remote_actor.id
      current_user_id = socket.assigns.current_user.id
      is_community = socket.assigns.remote_actor.actor_type == "Group"

      if socket.assigns.is_following || socket.assigns.is_pending do
        # Unfollow or cancel pending request
        case Elektrine.Profiles.unfollow_remote_actor(current_user_id, remote_actor_id) do
          {:ok, :unfollowed} ->
            message = if is_community, do: "Left community", else: "Unfollowed"

            {:noreply,
             socket
             |> assign(:is_following, false)
             |> assign(:is_pending, false)
             |> put_flash(:info, message)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:is_following, false)
             |> assign(:is_pending, false)
             |> put_flash(
               :error,
               if(is_community, do: "Failed to leave community", else: "Failed to unfollow")
             )}
        end
      else
        # Follow
        case Elektrine.Profiles.follow_remote_actor(current_user_id, remote_actor_id) do
          {:ok, follow} ->
            # Check if follow is pending (waiting for remote Accept)
            if follow.pending do
              message =
                if is_community,
                  do: "Join request sent! Waiting for approval.",
                  else: "Follow request sent!"

              {:noreply,
               socket
               |> assign(:is_pending, true)
               |> put_flash(:info, message)}
            else
              message = if is_community, do: "Joined community!", else: "Following!"

              {:noreply,
               socket
               |> assign(:is_following, true)
               |> assign(:is_pending, false)
               |> put_flash(:info, message)}
            end

          {:error, :already_following} ->
            {:noreply,
             socket
             |> assign(:is_following, true)
             |> put_flash(
               :info,
               if(is_community, do: "Already a member", else: "Already following")
             )}

          {:error, _reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               if(is_community, do: "Failed to join community", else: "Failed to follow")
             )}
        end
      end
    end
  end

  def handle_event("change_sort", %{"sort" => sort_by}, socket) do
    {:noreply, assign(socket, :sort_by, sort_by)}
  end

  def handle_event("open_external_post", %{"url" => url}, socket) do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("show_reply_form", %{"post_id" => post_id}, socket) do
    normalized_post_id = normalize_post_id_for_reply(socket, post_id)

    # First check timeline_posts (remote/outbox posts - maps with string keys)
    timeline_post =
      Enum.find(socket.assigns.timeline_posts, fn p -> p["id"] == normalized_post_id end)

    # If not found, check local_posts (Ecto schemas)
    local_post =
      Enum.find(socket.assigns.local_posts, fn p ->
        (p.activitypub_id || to_string(p.id)) == normalized_post_id
      end)

    reply_to_post =
      cond do
        timeline_post ->
          timeline_post

        local_post ->
          # Store just the normalized post_id for local posts since we need it for reply
          normalized_post_id

        true ->
          nil
      end

    fetch_target = timeline_post || local_post

    already_has_replies? =
      cond do
        is_nil(fetch_target) ->
          true

        match?(%{__struct__: _}, fetch_target) ->
          replies_for_post(fetch_target, socket.assigns.post_replies) != []

        is_map(fetch_target) ->
          Map.get(socket.assigns.post_replies || %{}, normalized_post_id, []) != []

        true ->
          true
      end

    if fetch_target && !already_has_replies? do
      liveview_pid = self()

      Task.start(fn ->
        case fetch_replies_for_post(fetch_target) do
          {fetched_post_id, replies}
          when is_binary(fetched_post_id) and is_list(replies) and replies != [] ->
            send(liveview_pid, {:replies_loaded_for_posts, %{fetched_post_id => replies}})

          _ ->
            :ok
        end
      end)
    end

    {:noreply,
     socket
     |> assign(:show_reply_form, true)
     |> assign(:reply_to_post, reply_to_post)
     |> assign(:reply_content, "")}
  end

  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    post_id = normalize_post_id_for_reply(socket, message_id)
    handle_event("show_reply_form", %{"post_id" => post_id}, socket)
  end

  def handle_event("show_reply_form", %{"id" => id}, socket) do
    post_id = normalize_post_id_for_reply(socket, id)
    handle_event("show_reply_form", %{"post_id" => post_id}, socket)
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_form, false)
     |> assign(:reply_to_post, nil)
     |> assign(:reply_content, "")}
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("update_reply_content", %{"value" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("submit_reply", _params, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to reply")}
    else
      if String.trim(socket.assigns.reply_content) == "" do
        {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
      else
        user = socket.assigns.current_user
        post = socket.assigns.reply_to_post

        # Handle both remote posts (maps) and local posts (just the post_id string)
        activitypub_id =
          cond do
            is_map(post) -> post["id"]
            is_binary(post) -> post
            true -> nil
          end

        # First, check if this post is already stored locally (we've seen it before)
        local_message = Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id)

        reply_to_id =
          if local_message do
            local_message.id
          else
            # Post not in our database yet - only try to fetch/store if it's a remote post (map)
            if is_map(post) do
              # Use store_remote_post which handles Create synchronously (bypasses queue)
              case Elektrine.ActivityPub.Handler.store_remote_post(
                     post,
                     socket.assigns.remote_actor.uri
                   ) do
                {:ok, message} when is_struct(message) -> message.id
                # Got raw object back, need message
                {:ok, %{"id" => _}} -> nil
                _ -> nil
              end
            else
              nil
            end
          end

        if reply_to_id do
          # Create reply with the local message id
          case Elektrine.Social.create_timeline_post(
                 user.id,
                 socket.assigns.reply_content,
                 visibility: "public",
                 reply_to_id: reply_to_id
               ) do
            {:ok, _reply} ->
              {:noreply,
               socket
               |> assign(:show_reply_form, false)
               |> assign(:reply_to_post, nil)
               |> assign(:reply_content, "")
               |> put_flash(
                 :info,
                 "Reply posted! It will be federated to #{socket.assigns.remote_actor.domain}"
               )}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to post reply")}
          end
        else
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
        end
      end
    end
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.like_post(socket.assigns.current_user.id, message.id) do
            {:ok, _like} ->
              key = PostInteractions.interaction_key(post_id, message)

              # Update interaction state and increment count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: true,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) + 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to like post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    handle_event(
      "like_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
      socket
    )
  end

  def handle_event("like_post", %{"id" => id}, socket) do
    handle_event("like_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          key = PostInteractions.interaction_key(post_id, message)

          case Elektrine.Social.unlike_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              # Update interaction state and decrement count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: false,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) - 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("unlike_post", %{"message_id" => message_id}, socket) do
    handle_event(
      "unlike_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
      socket
    )
  end

  def handle_event("unlike_post", %{"id" => id}, socket) do
    handle_event("unlike_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      # Check current like state
      current_state = socket.assigns.post_interactions[post_id] || %{liked: false}
      is_liked = Map.get(current_state, :liked, false)

      if is_liked do
        handle_event("unlike_post", %{"post_id" => post_id}, socket)
      else
        handle_event("like_post", %{"post_id" => post_id}, socket)
      end
    end
  end

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.boost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _boost} ->
              key = PostInteractions.interaction_key(post_id, message)

              # Update interaction state and decrement count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: true,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) + 1
                })

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> put_flash(:info, "Post boosted to your timeline!")}

            {:error, :already_boosted} ->
              {:noreply, put_flash(socket, :info, "You've already boosted this post")}

            {:error, :empty_post} ->
              {:noreply, put_flash(socket, :error, "Cannot boost empty posts")}

            {:error, :rate_limited} ->
              {:noreply,
               put_flash(socket, :error, "Slow down! You're boosting too fast (max 30/hour)")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    handle_event(
      "boost_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
      socket
    )
  end

  def handle_event("boost_post", %{"id" => id}, socket) do
    handle_event("boost_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("unboost_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          key = PostInteractions.interaction_key(post_id, message)

          case Elektrine.Social.unboost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              # Update interaction state and decrement count
              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: false,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) - 1
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("unboost_post", %{"message_id" => message_id}, socket) do
    handle_event(
      "unboost_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
      socket
    )
  end

  def handle_event("unboost_post", %{"id" => id}, socket) do
    handle_event("unboost_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("quote_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    else
      case resolve_quote_target(post_id, socket) do
        {:ok, quote_target} ->
          quote_target_ap_id = quote_target.activitypub_id || post_id

          {:noreply,
           socket
           |> assign(:show_quote_modal, true)
           |> assign(:quote_target_post, quote_target)
           |> assign(:quote_target_message_id, quote_target.id)
           |> assign(:quote_target_activitypub_id, quote_target_ap_id)
           |> assign(:quote_content, "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Post not found")}
      end
    end
  end

  def handle_event("quote_post", %{"message_id" => message_id}, socket) do
    handle_event(
      "quote_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id)},
      socket
    )
  end

  def handle_event("quote_post", %{"id" => id}, socket) do
    handle_event("quote_post", %{"post_id" => normalize_post_id_for_reply(socket, id)}, socket)
  end

  def handle_event("close_quote_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_quote_modal, false)
     |> assign(:quote_target_post, nil)
     |> assign(:quote_target_message_id, nil)
     |> assign(:quote_target_activitypub_id, nil)
     |> assign(:quote_content, "")}
  end

  def handle_event("update_quote_content", params, socket) do
    content = params["content"] || params["value"] || ""
    {:noreply, assign(socket, :quote_content, content)}
  end

  def handle_event("submit_quote", params, socket) do
    content = params["content"] || params["value"] || socket.assigns.quote_content || ""

    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to quote posts")}
    else
      quote_target_message_id = socket.assigns.quote_target_message_id
      quote_target_ap_id = socket.assigns.quote_target_activitypub_id

      cond do
        is_nil(quote_target_message_id) ->
          {:noreply, put_flash(socket, :error, "Quote target not found")}

        String.trim(content) == "" ->
          {:noreply, put_flash(socket, :error, "Please add some content to your quote")}

        true ->
          case Social.create_quote_post(
                 socket.assigns.current_user.id,
                 quote_target_message_id,
                 content
               ) do
            {:ok, _quote_post} ->
              updated_local_posts =
                increment_quote_count_for_local_posts(
                  socket.assigns.local_posts,
                  quote_target_message_id,
                  quote_target_ap_id
                )

              updated_timeline_posts =
                increment_quote_count_for_remote_posts(
                  socket.assigns.timeline_posts,
                  quote_target_ap_id
                )

              {:noreply,
               socket
               |> assign(:local_posts, updated_local_posts)
               |> assign(:timeline_posts, updated_timeline_posts)
               |> assign(:show_quote_modal, false)
               |> assign(:quote_target_post, nil)
               |> assign(:quote_target_message_id, nil)
               |> assign(:quote_target_activitypub_id, nil)
               |> assign(:quote_content, "")
               |> put_flash(:info, "Quote posted!")}

            {:error, :empty_quote} ->
              {:noreply, put_flash(socket, :error, "Quote content cannot be empty")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to create quote")}
          end
      end
    end
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      case PostInteractions.resolve_message_for_interaction(post_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          alias Elektrine.Messaging.Reactions
          key = PostInteractions.interaction_key(post_id, message)

          existing_reaction =
            Repo.get_by(Elektrine.Messaging.MessageReaction,
              message_id: message.id,
              user_id: user_id,
              emoji: emoji
            )

          if existing_reaction do
            case Reactions.remove_reaction(message.id, user_id, emoji) do
              {:ok, _} ->
                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    key,
                    %{emoji: emoji, user_id: user_id},
                    :remove
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, _} ->
                {:noreply, socket}
            end
          else
            case Reactions.add_reaction(message.id, user_id, emoji) do
              {:ok, reaction} ->
                reaction = Repo.preload(reaction, [:user, :remote_actor])

                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    key,
                    reaction,
                    :add
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, :rate_limited} ->
                {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

              {:error, _} ->
                {:noreply, socket}
            end
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def handle_event("react_to_post", %{"message_id" => message_id, "emoji" => emoji}, socket) do
    handle_event(
      "react_to_post",
      %{"post_id" => normalize_post_id_for_reply(socket, message_id), "emoji" => emoji},
      socket
    )
  end

  # Save/bookmark post handlers
  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    handle_event("save_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Social.save_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              key = PostInteractions.interaction_key(message_id, message)

              {:noreply,
               socket
               |> assign(:user_saves, Map.put(user_saves, key, true))
               |> put_flash(:info, "Saved")}

            {:error, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              key = PostInteractions.interaction_key(message_id, message)

              {:noreply,
               socket
               |> assign(:user_saves, Map.put(user_saves, key, true))
               |> put_flash(:info, "Already saved")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save post")}
      end
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    handle_event("unsave_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Social.unsave_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              key = PostInteractions.interaction_key(message_id, message)

              {:noreply,
               socket
               |> assign(:user_saves, Map.put(user_saves, key, false))
               |> put_flash(:info, "Removed from saved")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unsave")}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
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
        %{"url" => url, "images" => images_json, "index" => index} = params,
        socket
      ) do
    images = Jason.decode!(images_json)
    post_id = params["post_id"]

    # Find the post and attach remote_actor for the modal display
    modal_post =
      if post_id do
        # Try to find in local_posts first
        local_post =
          Enum.find(socket.assigns.local_posts, fn p ->
            (p.activitypub_id || to_string(p.id)) == post_id
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
     |> assign(:modal_image_index, String.to_integer(index))
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
    new_index = rem(socket.assigns.modal_image_index + 1, length(socket.assigns.modal_images))
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  def handle_event("prev_image", _params, socket) do
    total = length(socket.assigns.modal_images)
    new_index = rem(socket.assigns.modal_image_index - 1 + total, total)
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  def handle_event("next_media_post", _params, socket) do
    # Not implemented for remote user profiles
    {:noreply, socket}
  end

  def handle_event("prev_media_post", _params, socket) do
    # Not implemented for remote user profiles
    {:noreply, socket}
  end

  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" and url != "#" do
    trimmed_url = String.trim(url)

    case URI.parse(trimmed_url) do
      %URI{scheme: nil, host: nil} ->
        {:noreply, push_navigate(socket, to: trimmed_url)}

      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(trimmed_url)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("navigate_to_embedded_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_post", %{"post_id" => post_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, post_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_post", %{"message_id" => message_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, message_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_remote_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(url)}")}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, post_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_remote_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_external_link", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("open_external_link", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket)
      when is_binary(handle) and handle != "" do
    {:noreply, push_navigate(socket, to: "/#{handle}")}
  end

  def handle_event("navigate_to_profile", %{"username" => username}, socket)
      when is_binary(username) and username != "" do
    {:noreply, push_navigate(socket, to: "/#{username}")}
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

  def handle_event("toggle_create_post", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_post, !socket.assigns.show_create_post)
     |> assign(:post_title, "")
     |> assign(:post_content, "")
     |> assign(:pending_media_urls, [])
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
      |> Enum.map(fn {key, value} ->
        index = key |> String.replace("alt_text_", "") |> String.to_integer()
        {to_string(index), value}
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

  def handle_event("clear_pending_images", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_media_urls, [])
     |> assign(:pending_media_alt_texts, %{})}
  end

  def handle_event("submit_post", %{"content" => content} = params, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to post")}
    else
      title = Map.get(params, "title", "")
      content = String.trim(content)
      media_urls = socket.assigns.pending_media_urls
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
          if map_size(alt_texts) > 0 do
            %{"alt_texts" => alt_texts}
          else
            %{}
          end

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

  defp initial_community_stats(%{actor_type: "Group", metadata: metadata}) do
    metadata = metadata || %{}

    %{
      members: get_follower_count(metadata),
      posts: get_status_count(metadata)
    }
  end

  defp initial_community_stats(_), do: %{members: 0, posts: 0}

  defp fetch_group_stats(%{domain: domain, username: username, metadata: metadata}) do
    metadata = metadata || %{}
    metadata_stats = initial_community_stats(%{actor_type: "Group", metadata: metadata})

    followers_collection_count = fetch_collection_count(metadata["followers"])
    outbox_collection_count = fetch_collection_count(metadata["outbox"])
    lemmy_stats = LemmyApi.fetch_community_counts(domain, username) || %{}

    %{
      members:
        Enum.max([
          metadata_stats.members || 0,
          followers_collection_count,
          lemmy_stats[:members] || 0
        ]),
      posts:
        Enum.max([
          metadata_stats.posts || 0,
          outbox_collection_count,
          lemmy_stats[:posts] || 0
        ])
    }
  end

  defp fetch_group_stats(_), do: %{members: 0, posts: 0}

  # Helper functions - delegating to shared APHelpers module

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
  defp format_join_date(date), do: APHelpers.format_join_date(date)
  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)
  defp get_follower_count(meta), do: APHelpers.get_follower_count(meta)
  defp get_following_count(meta), do: APHelpers.get_following_count(meta)
  defp get_status_count(meta), do: APHelpers.get_status_count(meta)
  defp extract_username_from_uri(uri), do: APHelpers.extract_username_from_uri(uri)

  defp load_post_interactions(posts, user_id),
    do: APHelpers.load_post_interactions(posts, user_id)

  defp load_user_saves_for_posts(posts, user_id)
       when is_list(posts) and is_integer(user_id) do
    keyed_posts =
      posts
      |> Enum.filter(&is_struct(&1, Elektrine.Messaging.Message))
      |> Enum.map(fn post ->
        key = post.activitypub_id || Integer.to_string(post.id)
        {key, post.id}
      end)

    message_ids =
      keyed_posts
      |> Enum.map(fn {_key, message_id} -> message_id end)
      |> Enum.uniq()

    saved_ids = Social.list_user_saved_posts(user_id, message_ids)

    Enum.into(keyed_posts, %{}, fn {key, message_id} ->
      {key, MapSet.member?(saved_ids, message_id)}
    end)
  end

  defp load_user_saves_for_posts(_, _), do: %{}

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

  defp resolve_quote_target(post_id, socket) do
    post_id = to_string(post_id)

    with {:ok, message} <- resolve_quote_target_message(post_id, socket),
         quote_target <- load_quote_target_post(message) do
      {:ok, quote_target}
    end
  end

  defp resolve_quote_target_message(post_id, socket) do
    case Enum.find(socket.assigns.local_posts, fn post ->
           (post.activitypub_id || to_string(post.id)) == post_id
         end) do
      %Elektrine.Messaging.Message{} = message ->
        {:ok, message}

      _ ->
        PostInteractions.resolve_message_for_interaction(post_id,
          actor_uri: socket.assigns.remote_actor.uri
        )
    end
  end

  defp load_quote_target_post(%Elektrine.Messaging.Message{id: id}) do
    MessagingMessages.get_timeline_post!(id, force: true)
  rescue
    _ -> MessagingMessages.get_timeline_post!(id)
  end

  defp increment_quote_count_for_local_posts(posts, target_message_id, target_activitypub_id) do
    Enum.map(posts, fn post ->
      if post.id == target_message_id || post.activitypub_id == target_activitypub_id do
        %{post | quote_count: (post.quote_count || 0) + 1}
      else
        post
      end
    end)
  end

  defp increment_quote_count_for_remote_posts(posts, target_activitypub_id) do
    Enum.map(posts, fn post ->
      if post["id"] == target_activitypub_id do
        quote_count =
          max(
            max(
              get_collection_total_items(post["quoteCount"]),
              get_collection_total_items(post["quote_count"])
            ),
            get_collection_total_items(get_in(post, ["pleroma", "quote_count"]))
          )

        Map.put(post, "quoteCount", quote_count + 1)
      else
        post
      end
    end)
  end

  # Sorting functions for Lemmy-style post sorting
  def sort_posts(posts, sort_by) when is_list(posts) do
    case sort_by do
      "hot" -> sort_by_hot(posts)
      "top" -> sort_by_top(posts)
      "new" -> sort_by_new(posts)
      "old" -> sort_by_old(posts)
      "active" -> sort_by_active(posts)
      _ -> sort_by_hot(posts)
    end
  end

  defp sort_by_new(posts) do
    Enum.sort_by(posts, &get_post_timestamp/1, {:desc, DateTime})
  end

  defp sort_by_old(posts) do
    Enum.sort_by(posts, &get_post_timestamp/1, {:asc, DateTime})
  end

  defp sort_by_top(posts) do
    Enum.sort_by(posts, &get_post_score/1, :desc)
  end

  defp sort_by_active(posts) do
    # Sort by most recent activity (comments)
    Enum.sort_by(posts, &get_post_activity/1, :desc)
  end

  defp sort_by_hot(posts) do
    # Hot algorithm: combines score with recency
    # Similar to Reddit/Lemmy hot algorithm
    now = DateTime.utc_now()

    Enum.sort_by(
      posts,
      fn post ->
        score = get_post_score(post)
        age_hours = DateTime.diff(now, get_post_timestamp(post), :hour)
        # Gravity factor: posts decay over time
        gravity = 1.8
        # Hot score formula
        score / :math.pow(max(age_hours, 1) + 2, gravity)
      end,
      :desc
    )
  end

  defp get_post_timestamp(post) when is_map(post) do
    cond do
      # Local post (Ecto schema) - convert NaiveDateTime to DateTime
      Map.has_key?(post, :inserted_at) && post.inserted_at ->
        case post.inserted_at do
          %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC")
          %DateTime{} = dt -> dt
          _ -> DateTime.utc_now()
        end

      # Outbox post (ActivityPub object)
      is_binary(post["published"]) ->
        case DateTime.from_iso8601(post["published"]) do
          {:ok, dt, _} -> dt
          _ -> DateTime.utc_now()
        end

      true ->
        DateTime.utc_now()
    end
  end

  defp get_post_score(post) when is_map(post) do
    cond do
      # Local post with score field (Ecto schema)
      Map.has_key?(post, :score) && post.score ->
        post.score

      # Local post with upvotes/downvotes
      Map.has_key?(post, :upvotes) ->
        (post.upvotes || 0) - (post.downvotes || 0)

      # Local post with like_count only
      Map.has_key?(post, :like_count) && post.like_count ->
        post.like_count

      # Outbox post - check for likes object with totalItems
      is_map(post["likes"]) && post["likes"]["totalItems"] ->
        post["likes"]["totalItems"]

      # Lemmy/ActivityPub posts might have comment count as activity indicator
      # Use replies count as a proxy for engagement when no vote counts available
      is_map(post["replies"]) && post["replies"]["totalItems"] ->
        post["replies"]["totalItems"]

      # Check for replies as a map with items
      is_map(post["comments"]) && post["comments"]["totalItems"] ->
        post["comments"]["totalItems"]

      true ->
        0
    end
  end

  defp get_post_activity(post) when is_map(post) do
    cond do
      # Local post - use reply_count
      Map.has_key?(post, :reply_count) ->
        post.reply_count || 0

      # Outbox post - check for replies object
      is_map(post["replies"]) ->
        get_collection_total_items(post["replies"])

      true ->
        0
    end
  end

  defp normalize_post_id_for_reply(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        case Enum.find(socket.assigns.local_posts || [], &(&1.id == id)) do
          %{activitypub_id: activitypub_id}
          when is_binary(activitypub_id) and activitypub_id != "" ->
            activitypub_id

          %{id: local_id} when is_integer(local_id) ->
            Integer.to_string(local_id)

          _ ->
            to_string(decoded_value)
        end

      :error ->
        to_string(decoded_value)
    end
  end

  defp normalize_navigate_post_id(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        case Enum.find(socket.assigns.local_posts || [], &(&1.id == id)) do
          %{activitypub_id: activitypub_id}
          when is_binary(activitypub_id) and activitypub_id != "" ->
            activitypub_id

          _ ->
            Integer.to_string(id)
        end

      :error ->
        to_string(decoded_value)
    end
  end

  defp parse_local_message_id(value) when is_integer(value), do: {:ok, value}

  defp parse_local_message_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_local_message_id(_), do: :error

  defp decode_post_ref(value) when is_binary(value) do
    trimmed = String.trim(value)

    try do
      URI.decode_www_form(trimmed)
    rescue
      ArgumentError -> trimmed
    end
  end

  defp decode_post_ref(value), do: value

  defp likes_by_local_id(posts, post_interactions) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        state = interaction_state_for_local_post(post, post_interactions)
        Map.put(acc, id, Map.get(state, :liked, false))

      _, acc ->
        acc
    end)
  end

  defp likes_by_local_id(_, _), do: %{}

  defp boosts_by_local_id(posts, post_interactions) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        state = interaction_state_for_local_post(post, post_interactions)
        Map.put(acc, id, Map.get(state, :boosted, false))

      _, acc ->
        acc
    end)
  end

  defp boosts_by_local_id(_, _), do: %{}

  defp saves_by_local_id(posts, user_saves) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        Map.put(acc, id, post_saved?(post, user_saves))

      _, acc ->
        acc
    end)
  end

  defp saves_by_local_id(_, _), do: %{}

  defp replies_by_local_id(posts, post_replies) when is_list(posts) do
    Enum.reduce(posts, %{}, fn
      %{id: id} = post, acc when is_integer(id) ->
        Map.put(acc, id, replies_for_post(post, post_replies))

      _, acc ->
        acc
    end)
  end

  defp replies_by_local_id(_, _), do: %{}

  defp interaction_state_for_local_post(post, post_interactions) do
    key_candidates =
      [
        post.activitypub_id,
        Integer.to_string(post.id),
        post.id
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, PostInteractions.default_interaction_state(), fn key ->
      Map.get(post_interactions || %{}, key)
    end) || PostInteractions.default_interaction_state()
  end

  defp post_saved?(post, user_saves) do
    key_candidates =
      [
        post.activitypub_id,
        Integer.to_string(post.id),
        post.id
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, false, fn key ->
      case Map.get(user_saves || %{}, key) do
        nil -> nil
        value -> value
      end
    end) || false
  end

  defp replies_for_post(post, post_replies) do
    key_candidates =
      [
        post.activitypub_id,
        Integer.to_string(post.id),
        post.id
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(key_candidates, [], fn key ->
      case Map.get(post_replies || %{}, key) do
        nil -> nil
        value -> value
      end
    end) || []
  end

  defp normalize_post_reaction_keys(reactions_map) when is_map(reactions_map) do
    Enum.into(reactions_map, %{}, fn {key, reactions} ->
      {PostInteractions.normalize_key(key), reactions}
    end)
  end

  defp normalize_post_reaction_keys(_), do: %{}

  defp reactions_for_entry(%{id: id} = post, post_reactions) when is_integer(id) do
    keys =
      [post.activitypub_id, Integer.to_string(id), id]
      |> Enum.reject(&is_nil/1)

    reactions_for_keys(post_reactions, keys)
  end

  defp reactions_for_entry(_, _), do: []

  defp post_reaction_surface(post_ref, local_posts, post_reactions) do
    {target_id, value_name, keys} = reaction_target_for_post_ref(post_ref, local_posts)

    %{
      target_id: target_id,
      value_name: value_name,
      reactions: reactions_for_keys(post_reactions, keys)
    }
  end

  defp reply_reaction_surface(reply, local_posts, post_reactions) when is_map(reply) do
    reply_id = Map.get(reply, "id") || Map.get(reply, :id)
    local_message_id = Map.get(reply, "_local_message_id") || Map.get(reply, :_local_message_id)

    {target_id, value_name, keys} =
      case parse_local_message_id(local_message_id) do
        {:ok, id} ->
          reply_ref =
            if is_binary(reply_id) and reply_id != "" do
              reply_id
            else
              nil
            end

          {id, "message_id", [Integer.to_string(id), id, reply_ref]}

        :error ->
          reaction_target_for_post_ref(reply_id, local_posts)
      end

    %{
      target_id: target_id,
      value_name: value_name,
      reactions: reactions_for_keys(post_reactions, keys)
    }
  end

  defp reply_reaction_surface(_, _local_posts, _post_reactions) do
    %{target_id: nil, value_name: "post_id", reactions: []}
  end

  defp preview_reply_author(reply) when is_map(reply) do
    local_user = Map.get(reply, "_local_user") || Map.get(reply, :_local_user)

    if is_map(local_user) do
      username = Map.get(local_user, :username) || Map.get(local_user, "username")
      handle = Map.get(local_user, :handle) || Map.get(local_user, "handle") || username
      avatar = Map.get(local_user, :avatar) || Map.get(local_user, "avatar")

      avatar_url =
        if is_binary(avatar) && String.trim(avatar) != "" do
          Elektrine.Uploads.avatar_url(avatar)
        else
          nil
        end

      %{
        label: "@#{handle}@z.org",
        avatar_url: avatar_url,
        profile_path: if(is_binary(handle) && handle != "", do: "/#{handle}", else: nil)
      }
    else
      author_uri =
        Map.get(reply, "attributedTo") || Map.get(reply, :attributedTo) ||
          Map.get(reply, "actor") || Map.get(reply, :actor)

      fallback = SurfaceHelpers.build_reply_author_fallback(reply, author_uri)

      label =
        cond do
          is_binary(fallback.acct_label) && String.trim(fallback.acct_label) != "" ->
            fallback.acct_label

          is_binary(author_uri) && String.trim(author_uri) != "" ->
            "@#{extract_username_from_uri(author_uri)}"

          true ->
            "Remote user"
        end

      %{
        label: label,
        avatar_url: fallback.avatar_url,
        profile_path: fallback.profile_path
      }
    end
  end

  defp preview_reply_author(_), do: %{label: "Remote user", avatar_url: nil, profile_path: nil}

  defp reaction_target_for_post_ref(post_ref, local_posts) do
    decoded_ref = decode_post_ref(post_ref)

    case parse_local_message_id(decoded_ref) do
      {:ok, local_id} ->
        {
          local_id,
          "message_id",
          [Integer.to_string(local_id), local_id, to_string(decoded_ref)]
        }

      :error ->
        normalized_ref =
          if is_binary(decoded_ref), do: String.trim(decoded_ref), else: to_string(decoded_ref)

        local_match =
          Enum.find(local_posts || [], fn
            %{activitypub_id: activitypub_id} -> activitypub_id == normalized_ref
            _ -> false
          end)

        case local_match do
          %{id: local_id} when is_integer(local_id) ->
            {local_id, "message_id", [normalized_ref, Integer.to_string(local_id), local_id]}

          _ when is_binary(normalized_ref) and normalized_ref != "" ->
            {normalized_ref, "post_id", [normalized_ref]}

          _ ->
            {nil, "post_id", []}
        end
    end
  end

  defp reactions_for_keys(post_reactions, keys) when is_map(post_reactions) and is_list(keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(post_reactions, key) do
        reactions when is_list(reactions) -> reactions
        _ -> nil
      end
    end) || []
  end

  defp reactions_for_keys(_, _), do: []

  # Upload error helper
  defp error_to_string(:too_large), do: "File is too large (max 50MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 4)"
  defp error_to_string(:not_accepted), do: "Invalid file type"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])
end
