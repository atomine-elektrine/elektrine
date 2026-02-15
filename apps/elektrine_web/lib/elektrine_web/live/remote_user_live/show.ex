defmodule ElektrineWeb.RemoteUserLive.Show do
  use ElektrineWeb, :live_view

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.ActivityPub.Instances
  alias ElektrineWeb.Live.PostInteractions
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.{Repo, Social}

  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.Loaders.Skeleton

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

    # Load instance metadata (nodeinfo) for display
    instance_info =
      Instances.get_instance_with_metadata(remote_actor.domain, fetch_if_stale: true)

    socket
    |> assign(:page_title, "@#{remote_actor.username}@#{remote_actor.domain}")
    |> assign(:remote_actor, remote_actor)
    |> assign(:is_following, is_following)
    |> assign(:is_pending, is_pending)
    |> assign(:instance_info, instance_info)
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

      # Show local posts immediately
      socket =
        socket
        |> assign(:local_posts, local_posts)
        |> assign(:post_interactions, post_interactions)
        |> assign(:user_saves, user_saves)
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
        (current_local_posts ++ stored_posts)
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

      # Load replies/comments for newly discovered outbox posts.
      schedule_replies_fetch(unique_outbox_posts, self())

      {:noreply,
       socket
       |> assign(:local_posts, all_local_posts)
       |> assign(:post_interactions, post_interactions)
       |> assign(:user_saves, user_saves)}
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
    String.contains?(url, "/post/") ||
      Regex.match?(~r{/c/[^/]+/p/}, url) ||
      Regex.match?(~r{/m/[^/]+/p/}, url) ||
      Regex.match?(~r{/m/[^/]+/t/}, url)
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
      # Skip if no ID or already exists
      if post["id"] && !Messaging.get_message_by_activitypub_id(post["id"]) do
        # Get or fetch the author actor
        author_uri = post["attributedTo"] || remote_actor.uri

        author_actor =
          case ActivityPub.get_or_fetch_actor(author_uri) do
            {:ok, actor} -> actor
            _ -> nil
          end

        if author_actor do
          # Extract content and metadata
          content = post["content"] || post["name"] || ""
          title = post["name"]

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

          # Build metadata
          metadata =
            %{
              "type" => post["type"],
              "url" => post["url"],
              "community_actor_uri" => remote_actor.uri,
              "sensitive" => post["sensitive"],
              "quoteUrl" => post["quoteUrl"] || post["_misskey_quote"],
              "replies" => post["replies"],
              "comments" => post["comments"],
              "likes" => post["likes"],
              "shares" => post["shares"]
            }
            |> Map.merge(alt_texts)

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
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
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
    # First check timeline_posts (remote/outbox posts - maps with string keys)
    reply_to_post = Enum.find(socket.assigns.timeline_posts, fn p -> p["id"] == post_id end)

    # If not found, check local_posts (Ecto schemas)
    reply_to_post =
      if reply_to_post do
        reply_to_post
      else
        local_post =
          Enum.find(socket.assigns.local_posts, fn p ->
            (p.activitypub_id || to_string(p.id)) == post_id
          end)

        # Store just the post_id for local posts since we need it for reply
        if local_post, do: post_id, else: nil
      end

    {:noreply,
     socket
     |> assign(:show_reply_form, true)
     |> assign(:reply_to_post, reply_to_post)
     |> assign(:reply_content, "")}
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

  def handle_event("navigate_to_post", %{"post_id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: "/remote/post/#{post_id}")}
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

  # Helper functions - delegating to shared APHelpers module

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
  defp format_join_date(date), do: APHelpers.format_join_date(date)
  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)
  defp get_follower_count(meta), do: APHelpers.get_follower_count(meta)
  defp get_following_count(meta), do: APHelpers.get_following_count(meta)
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

  # Upload error helper
  defp error_to_string(:too_large), do: "File is too large (max 50MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 4)"
  defp error_to_string(:not_accepted), do: "Invalid file type"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])
end
