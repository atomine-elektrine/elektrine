defmodule Elektrine.ActivityPub.RefreshCountsWorker do
  @moduledoc """
  Background worker that periodically refreshes engagement counts
  (likes, shares, replies) for cached remote posts.

  This ensures that cached posts stay up-to-date with the original
  server's counts, which can change as users interact with the post
  on the original instance.

  ## Strategy

  1. Recent posts (< 24h old) are refreshed more frequently
  2. Popular posts (high engagement) are prioritized
  3. Posts users have interacted with are synced promptly
  4. Uses platform-specific APIs (Lemmy, Mastodon) when available
  5. Falls back to ActivityPub collection fetching
  6. Domain throttling prevents spamming any single instance
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    priority: 3

  require Logger

  import Ecto.Query

  alias Elektrine.ActivityPub.{CollectionFetcher, LemmyApi, MastodonApi, Normalizer, RemoteFetch}
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages
  alias Elektrine.Social.PostBoost
  alias Elektrine.Social.PostLike

  @batch_size 50
  @recent_threshold_hours 24
  @stale_threshold_hours 6
  @visible_refresh_limit 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "refresh_recent"}}) do
    refresh_recent_posts()
    :ok
  end

  def perform(%Oban.Job{args: %{"type" => "refresh_popular"}}) do
    refresh_popular_posts()
    :ok
  end

  def perform(%Oban.Job{args: %{"type" => "refresh_interacted"}}) do
    refresh_interacted_posts()
    :ok
  end

  def perform(%Oban.Job{args: %{"type" => "refresh_single", "message_id" => message_id}}) do
    refresh_single_post(message_id)
    :ok
  end

  def perform(%Oban.Job{}) do
    # Default: refresh a batch of stale posts
    refresh_stale_posts()
    :ok
  end

  @doc """
  Enqueue a refresh job for recent posts.
  """
  def schedule_recent_refresh do
    %{"type" => "refresh_recent"}
    |> new(schedule_in: 60)
    |> Elektrine.JobQueue.insert()
  end

  @doc """
  Enqueue a refresh job for popular posts.
  """
  def schedule_popular_refresh do
    %{"type" => "refresh_popular"}
    |> new(schedule_in: 60)
    |> Elektrine.JobQueue.insert()
  end

  @doc """
  Enqueue a refresh for posts users have interacted with.
  """
  def schedule_interacted_refresh do
    %{"type" => "refresh_interacted"}
    |> new(schedule_in: 60)
    |> Elektrine.JobQueue.insert()
  end

  @doc """
  Schedules a refresh for a specific post.
  Useful when viewing a remote post's detail page.
  """
  def schedule_single_refresh(message_id) do
    %{"type" => "refresh_single", "message_id" => message_id}
    |> new(unique: [period: 300, keys: [:message_id]])
    |> Elektrine.JobQueue.insert()
  end

  @doc """
  Returns refresh candidate ids from a visible post list.

  Visible feed surfaces should use this before enqueueing refresh jobs so timeline,
  portal, and communities all share the same ActivityPub eligibility rules.
  """
  def visible_refresh_candidate_ids(posts, opts \\ [])

  def visible_refresh_candidate_ids(posts, opts) when is_list(posts) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @visible_refresh_limit)

    if is_integer(limit) and limit > 0 do
      posts
      |> Enum.flat_map(&visible_refresh_candidate_targets/1)
      |> Enum.uniq()
      |> Enum.take(limit)
    else
      []
    end
  end

  def visible_refresh_candidate_ids(_posts, _opts), do: []

  @doc """
  Enqueues count refreshes for visible federated posts and returns the message ids scheduled.
  """
  def schedule_visible_refreshes(posts, opts \\ []) do
    message_ids = visible_refresh_candidate_ids(posts, opts)

    Enum.each(message_ids, fn message_id ->
      _ = schedule_single_refresh(message_id)
    end)

    message_ids
  end

  @doc """
  Immediately refresh a post's counts using the best available API.
  Returns {:ok, updated_counts} or {:error, reason}.
  Useful for synchronous refresh when viewing a post.
  """
  def refresh_now(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :not_found}
      message -> do_refresh_post(message)
    end
  end

  @doc false
  def reconcile_refreshed_engagement_counts(post, remote_counts) when is_map(remote_counts) do
    remote_counts
    |> Map.put(
      :like_count,
      reconciled_refreshed_like_count(post, Map.get(remote_counts, :like_count))
    )
    |> Map.put(
      :reply_count,
      reconciled_refreshed_reply_count(post, Map.get(remote_counts, :reply_count))
    )
    |> Map.put(
      :share_count,
      reconciled_refreshed_share_count(post, Map.get(remote_counts, :share_count))
    )
  end

  def reconcile_refreshed_engagement_counts(_post, remote_counts), do: remote_counts

  # Private implementation

  defp refresh_recent_posts do
    recent_cutoff = DateTime.utc_now() |> DateTime.add(-@recent_threshold_hours * 3600, :second)

    posts =
      from(m in Message,
        where: m.federated == true,
        where: not is_nil(m.remote_actor_id),
        where: m.inserted_at > ^recent_cutoff,
        where: is_nil(m.deleted_at),
        order_by: [desc: m.inserted_at],
        limit: ^@batch_size,
        select: [
          :id,
          :activitypub_id,
          :activitypub_url,
          :like_count,
          :reply_count,
          :share_count,
          :quote_count,
          :upvotes,
          :downvotes,
          :score,
          :media_metadata
        ]
      )
      |> Repo.all()

    refresh_posts_batch(posts)
  end

  defp refresh_popular_posts do
    # Posts with high engagement that might have changed
    posts =
      from(m in Message,
        where: m.federated == true,
        where: not is_nil(m.remote_actor_id),
        where: is_nil(m.deleted_at),
        where: m.like_count > 5 or m.reply_count > 2 or m.share_count > 1,
        order_by: [
          desc: fragment("? + ? * 2 + ? * 3", m.like_count, m.reply_count, m.share_count)
        ],
        limit: ^@batch_size,
        select: [
          :id,
          :activitypub_id,
          :activitypub_url,
          :like_count,
          :reply_count,
          :share_count,
          :quote_count,
          :upvotes,
          :downvotes,
          :score,
          :media_metadata
        ]
      )
      |> Repo.all()

    refresh_posts_batch(posts)
  end

  defp refresh_stale_posts do
    stale_cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_hours * 3600, :second)

    # Find posts that haven't been refreshed recently
    # We use updated_at as a proxy for "last refreshed"
    posts =
      from(m in Message,
        where: m.federated == true,
        where: not is_nil(m.remote_actor_id),
        where: is_nil(m.deleted_at),
        where: m.updated_at < ^stale_cutoff or is_nil(m.updated_at),
        order_by: [asc: m.updated_at],
        limit: ^@batch_size,
        select: [
          :id,
          :activitypub_id,
          :activitypub_url,
          :like_count,
          :reply_count,
          :share_count,
          :quote_count,
          :upvotes,
          :downvotes,
          :score,
          :media_metadata
        ]
      )
      |> Repo.all()

    refresh_posts_batch(posts)
  end

  defp refresh_interacted_posts do
    # Find remote posts that local users have interacted with recently
    # This includes posts they liked, replied to, or boosted
    recent_cutoff = DateTime.utc_now() |> DateTime.add(-24 * 3600, :second)

    # Posts that have received federated likes (from remote users to local posts,
    # or local users to remote posts - tracked via FederatedLike)
    liked_post_ids =
      from(l in Elektrine.Messaging.FederatedLike,
        where: l.inserted_at > ^recent_cutoff,
        join: m in Message,
        on: m.id == l.message_id,
        where: m.federated == true and not is_nil(m.remote_actor_id),
        select: m.id
      )
      |> Repo.all()

    # Posts that have received local replies
    replied_post_ids =
      from(m in Message,
        where: m.inserted_at > ^recent_cutoff,
        where: not is_nil(m.reply_to_id),
        join: parent in Message,
        on: parent.id == m.reply_to_id,
        where: parent.federated == true and not is_nil(parent.remote_actor_id),
        select: parent.id
      )
      |> Repo.all()

    # Posts that have received federated boosts
    boosted_post_ids =
      from(b in Elektrine.Messaging.FederatedBoost,
        where: b.inserted_at > ^recent_cutoff,
        join: m in Message,
        on: m.id == b.message_id,
        where: m.federated == true and not is_nil(m.remote_actor_id),
        select: m.id
      )
      |> Repo.all()

    # Combine and deduplicate
    all_ids =
      (liked_post_ids ++ replied_post_ids ++ boosted_post_ids)
      |> Enum.uniq()
      |> Enum.take(@batch_size)

    if all_ids != [] do
      posts =
        from(m in Message,
          where: m.id in ^all_ids,
          select: [
            :id,
            :activitypub_id,
            :activitypub_url,
            :like_count,
            :reply_count,
            :share_count,
            :quote_count,
            :upvotes,
            :downvotes,
            :score,
            :media_metadata
          ]
        )
        |> Repo.all()

      refresh_posts_batch(posts)
    end
  end

  defp refresh_single_post(message_id) do
    case Repo.get(Message, message_id) do
      nil ->
        Logger.debug("Post #{message_id} not found for refresh")
        :ok

      message ->
        refresh_post(message)
    end
  end

  defp visible_refresh_candidate?(post) when is_map(post) do
    is_integer(post_field(post, :id)) &&
      post_field(post, :federated) == true &&
      has_activitypub_count_reference?(post)
  end

  defp visible_refresh_candidate?(_post), do: false

  defp visible_refresh_candidate_targets(post) when is_map(post) do
    [post, post_field(post, :shared_message)]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&visible_refresh_candidate?/1)
    |> Enum.map(&post_field(&1, :id))
  end

  defp visible_refresh_candidate_targets(_post), do: []

  defp has_activitypub_count_reference?(post) do
    [:activitypub_id, :activitypub_url]
    |> Enum.map(&post_field(post, &1))
    |> Enum.any?(&(is_binary(&1) && String.trim(&1) != ""))
  end

  defp post_field(post, key) when is_map(post) and is_atom(key) do
    Map.get(post, key) || Map.get(post, Atom.to_string(key))
  end

  defp refresh_posts_batch(posts) do
    # Group posts by platform type for efficient batch fetching
    {lemmy_posts, other_posts} = Enum.split_with(posts, &lemmy_url?(&1.activitypub_id))

    {mastodon_posts, activitypub_posts} =
      Enum.split_with(other_posts, &MastodonApi.count_api_compatible?/1)

    # Batch fetch Lemmy posts (uses parallel requests internally)
    if lemmy_posts != [] do
      refresh_lemmy_batch(lemmy_posts)
    end

    # Batch fetch Mastodon posts (uses parallel requests internally)
    if mastodon_posts != [] do
      refresh_mastodon_batch(mastodon_posts)
    end

    # Process remaining posts individually with domain throttling
    if activitypub_posts != [] do
      refresh_activitypub_posts(activitypub_posts)
    end
  end

  defp refresh_activitypub_posts(activitypub_posts) do
    activitypub_posts
    |> Enum.group_by(&extract_domain/1)
    |> Enum.each(fn {_domain, domain_posts} -> refresh_domain_posts(domain_posts) end)
  end

  defp refresh_domain_posts(domain_posts) do
    Enum.each(domain_posts, fn post ->
      refresh_post(post)
      Process.sleep(100)
    end)
  end

  defp refresh_lemmy_batch(posts) do
    # Use LemmyApi's batch fetching
    counts_map = LemmyApi.fetch_posts_counts(posts)

    Enum.each(posts, fn post ->
      refresh_lemmy_post(post, Map.get(counts_map, post.activitypub_id))
    end)
  end

  defp refresh_lemmy_post(post, %{score: score, comments: comments} = counts) do
    updated_counts = %{
      like_count: normalize_remote_count(score),
      reply_count: normalize_remote_count(comments),
      share_count: 0,
      upvotes: normalize_remote_count(counts.upvotes),
      downvotes: normalize_remote_count(counts.downvotes),
      score: normalize_remote_count(score)
    }

    updated_counts = reconcile_refreshed_engagement_counts(post, updated_counts)

    media_metadata = merge_original_count_metadata(post.media_metadata, score, comments, 0)
    metadata_changed? = media_metadata != normalize_status_metadata(post.media_metadata)

    if refreshed_counts_changed?(post, updated_counts) || metadata_changed? do
      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [
          like_count: updated_counts.like_count,
          reply_count: updated_counts.reply_count,
          share_count: updated_counts.share_count,
          upvotes: updated_counts.upvotes,
          downvotes: updated_counts.downvotes,
          score: updated_counts.score,
          media_metadata: media_metadata,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      Messages.broadcast_post_counts_updated(post.id, updated_counts)
    end
  end

  defp refresh_lemmy_post(post, nil) do
    # Fallback to individual refresh
    refresh_post(post)
  end

  defp refresh_mastodon_batch(posts) do
    # Use MastodonApi's batch fetching
    counts_map = MastodonApi.fetch_statuses_counts(posts)

    Enum.each(posts, fn post ->
      refresh_mastodon_post(post, Map.get(counts_map, post.activitypub_id))
    end)
  end

  defp refresh_mastodon_post(
         post,
         %{
           favourites_count: fav,
           reblogs_count: reb,
           replies_count: rep
         } = counts
       ) do
    quotes = normalize_remote_count(Map.get(counts, :quotes_count))
    status_metadata = normalize_status_metadata(Map.get(counts, :status_metadata))

    media_metadata =
      post.media_metadata
      |> merge_status_metadata(status_metadata, quotes)
      |> merge_original_count_metadata(fav, rep, reb)

    metadata_changed? = media_metadata != normalize_status_metadata(post.media_metadata)

    updated_counts = %{
      like_count: normalize_remote_count(fav),
      reply_count: normalize_remote_count(rep),
      share_count: normalize_remote_count(reb),
      quote_count: quotes
    }

    updated_counts = reconcile_refreshed_engagement_counts(post, updated_counts)

    if refreshed_counts_changed?(post, updated_counts) ||
         (post.quote_count || 0) != quotes ||
         metadata_changed? do
      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [
          like_count: updated_counts.like_count,
          reply_count: updated_counts.reply_count,
          share_count: updated_counts.share_count,
          quote_count: updated_counts.quote_count,
          media_metadata: media_metadata,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      Messages.broadcast_post_counts_updated(post.id, updated_counts)
    end
  end

  defp refresh_mastodon_post(post, nil) do
    # Fallback to ActivityPub refresh
    refresh_post(post)
  end

  defp refresh_post(%{activitypub_id: nil}), do: :ok

  defp refresh_post(post) do
    do_refresh_post(post)
    :ok
  rescue
    e ->
      Logger.warning("Error refreshing post #{post.id}: #{inspect(e)}")
      :ok
  end

  defp do_refresh_post(%{id: id, activitypub_id: ap_id} = post) do
    # Try platform-specific APIs first (more reliable counts), then fall back to ActivityPub
    case fetch_counts_smart(post) do
      {:ok, new_counts} ->
        normalized_counts = normalize_counts(new_counts)
        maybe_update_refreshed_counts(post, id, ap_id, normalized_counts)

      {:error, reason} ->
        Logger.debug("Failed to refresh #{ap_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_counts(new_counts) do
    %{
      like_count: new_counts[:like_count] || new_counts[:favourites_count] || 0,
      reply_count:
        new_counts[:reply_count] || new_counts[:replies_count] || new_counts[:comments] || 0,
      share_count: new_counts[:share_count] || new_counts[:reblogs_count] || 0,
      quote_count: new_counts[:quote_count] || new_counts[:quotes_count] || 0,
      upvotes: new_counts[:upvotes] || get_in(new_counts, [:raw, :upvotes]) || 0,
      downvotes: new_counts[:downvotes] || get_in(new_counts, [:raw, :downvotes]) || 0,
      score:
        new_counts[:score] || get_in(new_counts, [:raw, :score]) ||
          new_counts[:like_count] ||
          new_counts[:favourites_count] || 0,
      status_metadata: normalize_status_metadata(new_counts[:status_metadata])
    }
  end

  defp maybe_update_refreshed_counts(post, id, ap_id, %{
         like_count: likes,
         reply_count: replies,
         share_count: shares,
         quote_count: quotes,
         upvotes: upvotes,
         downvotes: downvotes,
         score: score,
         status_metadata: status_metadata
       }) do
    media_metadata =
      post.media_metadata
      |> merge_status_metadata(status_metadata, quotes)
      |> merge_original_count_metadata(likes, replies, shares)

    metadata_changed? = media_metadata != normalize_status_metadata(post.media_metadata)

    updated_counts = %{
      like_count: normalize_remote_count(likes),
      reply_count: normalize_remote_count(replies),
      share_count: normalize_remote_count(shares),
      quote_count: normalize_remote_count(quotes),
      upvotes: normalize_remote_count(upvotes),
      downvotes: normalize_remote_count(downvotes),
      score: normalize_remote_count(score)
    }

    updated_counts = reconcile_refreshed_engagement_counts(post, updated_counts)

    if refreshed_counts_changed?(post, updated_counts) ||
         (post.quote_count || 0) != quotes ||
         (post.upvotes || 0) != upvotes ||
         (post.downvotes || 0) != downvotes ||
         (post.score || 0) != score ||
         metadata_changed? do
      Repo.update_all(
        from(m in Message, where: m.id == ^id),
        set: [
          like_count: updated_counts.like_count,
          reply_count: updated_counts.reply_count,
          share_count: updated_counts.share_count,
          quote_count: updated_counts.quote_count,
          upvotes: updated_counts.upvotes,
          downvotes: updated_counts.downvotes,
          score: updated_counts.score,
          media_metadata: media_metadata,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      Messages.broadcast_post_counts_updated(id, updated_counts)

      Logger.debug(
        "Refreshed counts for #{ap_id}: likes=#{likes}, replies=#{replies}, shares=#{shares}"
      )

      {:ok, updated_counts}
    else
      {:ok,
       %{
         like_count: post.like_count,
         reply_count: post.reply_count,
         share_count: post.share_count,
         quote_count: post.quote_count || 0,
         upvotes: post.upvotes || 0,
         downvotes: post.downvotes || 0,
         score: post.score || 0,
         status_metadata: status_metadata
       }}
    end
  end

  # Intelligently fetch counts using the best available API for each platform
  defp fetch_counts_smart(%{activitypub_id: _ap_id} = post) do
    count_ref = count_reference(post)
    lemmy_ref = lemmy_reference(post)

    cond do
      # Lemmy posts: use Lemmy API (most reliable)
      is_binary(lemmy_ref) ->
        case LemmyApi.fetch_post_counts(lemmy_ref) do
          %{score: score, comments: comments} = counts ->
            {:ok, %{like_count: score, reply_count: comments, share_count: 0, raw: counts}}

          nil ->
            fetch_counts_activitypub(count_ref)
        end

      # Mastodon-compatible and Misskey note URLs: use instance-specific counts API
      MastodonApi.count_api_compatible?(post) ->
        case MastodonApi.fetch_status_counts_for_post(post) do
          %{favourites_count: fav, reblogs_count: reb, replies_count: rep} = counts ->
            {:ok,
             %{
               like_count: fav,
               reply_count: rep,
               share_count: reb,
               quote_count: Map.get(counts, :quotes_count, 0),
               status_metadata: Map.get(counts, :status_metadata, %{})
             }}

          nil ->
            fetch_counts_activitypub(count_ref)
        end

      # Fallback: use ActivityPub
      is_binary(count_ref) ->
        fetch_counts_activitypub(count_ref)

      true ->
        {:error, :invalid_activitypub_id}
    end
  end

  defp fetch_counts_smart(ap_id) when is_binary(ap_id),
    do: fetch_counts_smart(%{activitypub_id: ap_id})

  defp fetch_counts_smart(_), do: {:error, :invalid_activitypub_id}

  defp fetch_counts_activitypub(ap_id) do
    case RemoteFetch.fetch_object(ap_id) do
      {:ok, object} ->
        counts = Normalizer.engagement_counts(object)

        {:ok,
         Map.take(counts, [
           :like_count,
           :reply_count,
           :share_count,
           :quote_count,
           :upvotes,
           :downvotes,
           :score
         ])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_remote_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_remote_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} -> max(count, 0)
      :error -> 0
    end
  end

  defp normalize_remote_count(nil), do: 0
  defp normalize_remote_count(_), do: 0

  defp normalize_status_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_status_metadata(_), do: %{}

  defp merge_status_metadata(existing_metadata, status_metadata, quote_count) do
    status_metadata = normalize_status_metadata(status_metadata)
    quote_count = normalize_remote_count(quote_count)

    quote_count_metadata =
      Map.get(status_metadata, "quotes_count") || if(quote_count > 0, do: quote_count)

    existing_metadata
    |> normalize_status_metadata()
    |> maybe_put_status_metadata("emoji_reactions", Map.get(status_metadata, "emoji_reactions"))
    |> maybe_put_status_metadata("quotes_count", quote_count_metadata)
    |> maybe_put_status_metadata("quote", Map.get(status_metadata, "quote"))
    |> maybe_put_status_metadata("quote_id", Map.get(status_metadata, "quote_id"))
    |> maybe_put_status_metadata("quote_url", Map.get(status_metadata, "quote_url"))
    |> maybe_put_status_metadata("card", Map.get(status_metadata, "card"))
    |> maybe_put_status_metadata("application", Map.get(status_metadata, "application"))
    |> maybe_put_status_metadata("language", Map.get(status_metadata, "language"))
    |> maybe_put_status_metadata(
      "media_attachments",
      Map.get(status_metadata, "media_attachments")
    )
    |> maybe_put_status_metadata("pleroma", Map.get(status_metadata, "pleroma"))
    |> maybe_put_status_metadata("misskey", Map.get(status_metadata, "misskey"))
  end

  defp maybe_put_status_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_status_metadata(metadata, _key, []), do: metadata

  defp maybe_put_status_metadata(metadata, _key, %{} = value) when map_size(value) == 0,
    do: metadata

  defp maybe_put_status_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp merge_original_count_metadata(metadata, likes, replies, shares) do
    metadata
    |> normalize_status_metadata()
    |> maybe_put_original_count("original_like_count", likes)
    |> maybe_put_original_count("original_reply_count", replies)
    |> maybe_put_original_count("original_share_count", shares)
  end

  defp maybe_put_original_count(metadata, key, value) do
    existing = normalize_remote_count(Map.get(metadata, key))
    value = normalize_remote_count(value)
    merged = max(existing, value)

    if merged > 0 do
      Map.put(metadata, key, merged)
    else
      metadata
    end
  end

  defp reconciled_refreshed_like_count(%{id: message_id} = post, remote_like_count)
       when is_integer(message_id) do
    [
      post.like_count,
      remote_like_count,
      get_in(normalize_status_metadata(post.media_metadata), ["original_like_count"]),
      local_like_count(message_id)
    ]
    |> Enum.map(&normalize_remote_count/1)
    |> Enum.max(fn -> 0 end)
  end

  defp reconciled_refreshed_like_count(_post, remote_like_count),
    do: normalize_remote_count(remote_like_count)

  defp reconciled_refreshed_reply_count(%{id: message_id} = post, remote_reply_count)
       when is_integer(message_id) do
    [
      post.reply_count,
      remote_reply_count,
      get_in(normalize_status_metadata(post.media_metadata), ["original_reply_count"]),
      local_reply_count(message_id)
    ]
    |> Enum.map(&normalize_remote_count/1)
    |> Enum.max(fn -> 0 end)
  end

  defp reconciled_refreshed_reply_count(_post, remote_reply_count),
    do: normalize_remote_count(remote_reply_count)

  defp reconciled_refreshed_share_count(%{id: message_id} = post, remote_share_count)
       when is_integer(message_id) do
    [
      post.share_count,
      remote_share_count,
      get_in(normalize_status_metadata(post.media_metadata), ["original_share_count"]),
      local_share_count(message_id)
    ]
    |> Enum.map(&normalize_remote_count/1)
    |> Enum.max(fn -> 0 end)
  end

  defp reconciled_refreshed_share_count(_post, remote_share_count),
    do: normalize_remote_count(remote_share_count)

  defp local_like_count(message_id) do
    from(l in PostLike,
      where: l.message_id == ^message_id,
      select: count(l.id)
    )
    |> Repo.one()
    |> normalize_remote_count()
  end

  defp local_reply_count(message_id) do
    from(m in Message,
      where: m.reply_to_id == ^message_id and is_nil(m.deleted_at),
      select: count(m.id)
    )
    |> Repo.one()
    |> normalize_remote_count()
  end

  defp local_share_count(message_id) do
    from(b in PostBoost,
      where: b.message_id == ^message_id,
      select: count(b.id)
    )
    |> Repo.one()
    |> normalize_remote_count()
  end

  defp refreshed_counts_changed?(post, counts) when is_map(counts) do
    (post.like_count || 0) != Map.get(counts, :like_count, 0) ||
      (post.reply_count || 0) != Map.get(counts, :reply_count, 0) ||
      (post.share_count || 0) != Map.get(counts, :share_count, 0)
  end

  defp lemmy_url?(url) when is_binary(url) do
    LemmyApi.community_post_url?(url) or Regex.match?(~r{/comment/\d+(?:$|[/?#])}, url)
  end

  defp lemmy_url?(_), do: false

  defp lemmy_reference(post) do
    [Map.get(post, :activitypub_id), Map.get(post, :activitypub_url)]
    |> Enum.find(&lemmy_url?/1)
  end

  defp count_reference(post) do
    [Map.get(post, :activitypub_id), Map.get(post, :activitypub_url)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp extract_domain(%{activitypub_id: nil}), do: "unknown"

  defp extract_domain(%{activitypub_id: ap_id}) do
    case URI.parse(ap_id) do
      %URI{host: host} when is_binary(host) -> host
      _ -> "unknown"
    end
  end

  @doc """
  Fetches who liked a post from the remote server.
  Returns a list of actor/account info.
  Uses platform-specific APIs when available.
  """
  def fetch_likers(message) do
    if MastodonApi.count_api_compatible?(message) do
      # Mastodon/Pleroma/Misskey APIs provide user info directly.
      case MastodonApi.fetch_favourited_by_for_post(message) do
        {:ok, accounts} -> {:ok, accounts}
        {:error, _} -> fetch_likers_activitypub(message)
      end
    else
      # Lemmy doesn't expose individual likers, fall back
      fetch_likers_activitypub(message)
    end
  end

  defp fetch_likers_activitypub(message) do
    case RemoteFetch.fetch_object(message.activitypub_id) do
      {:ok, object} ->
        likes_collection = Normalizer.interaction_collection(object, :likes)

        case CollectionFetcher.fetch_interaction_actors(likes_collection, max_items: 50) do
          {:ok, actors} -> {:ok, actors}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches who shared/boosted a post from the remote server.
  Returns a list of actor/account info.
  Uses platform-specific APIs when available.
  """
  def fetch_sharers(message) do
    if MastodonApi.count_api_compatible?(message) do
      # Mastodon/Pleroma/Misskey APIs provide user info directly.
      case MastodonApi.fetch_reblogged_by_for_post(message) do
        {:ok, accounts} -> {:ok, accounts}
        {:error, _} -> fetch_sharers_activitypub(message)
      end
    else
      # Lemmy doesn't have boosts, fall back
      fetch_sharers_activitypub(message)
    end
  end

  defp fetch_sharers_activitypub(message) do
    case RemoteFetch.fetch_object(message.activitypub_id) do
      {:ok, object} ->
        shares_collection = Normalizer.interaction_collection(object, :shares)

        case CollectionFetcher.fetch_interaction_actors(shares_collection, max_items: 50) do
          {:ok, actors} -> {:ok, actors}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
