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

  alias Elektrine.ActivityPub.{CollectionFetcher, Fetcher, Helpers, LemmyApi, MastodonApi}
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  @batch_size 50
  @recent_threshold_hours 24
  @stale_threshold_hours 6

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
  Schedules a refresh job for recent posts.
  Call this from a scheduler (e.g., Quantum) every hour.
  """
  def schedule_recent_refresh do
    %{"type" => "refresh_recent"}
    |> new(schedule_in: 60)
    |> Oban.insert()
  end

  @doc """
  Schedules a refresh job for popular posts.
  Call this from a scheduler every 4 hours.
  """
  def schedule_popular_refresh do
    %{"type" => "refresh_popular"}
    |> new(schedule_in: 60)
    |> Oban.insert()
  end

  @doc """
  Schedules a refresh for posts users have interacted with.
  Call this from a scheduler every 30 minutes.
  """
  def schedule_interacted_refresh do
    %{"type" => "refresh_interacted"}
    |> new(schedule_in: 60)
    |> Oban.insert()
  end

  @doc """
  Schedules a refresh for a specific post.
  Useful when viewing a remote post's detail page.
  """
  def schedule_single_refresh(message_id) do
    %{"type" => "refresh_single", "message_id" => message_id}
    |> new(unique: [period: 300, keys: [:message_id]])
    |> Oban.insert()
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
        select: [:id, :activitypub_id, :like_count, :reply_count, :share_count]
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
        select: [:id, :activitypub_id, :like_count, :reply_count, :share_count]
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
        select: [:id, :activitypub_id, :like_count, :reply_count, :share_count]
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
          select: [:id, :activitypub_id, :like_count, :reply_count, :share_count]
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

  defp refresh_posts_batch(posts) do
    # Group posts by platform type for efficient batch fetching
    {lemmy_posts, other_posts} = Enum.split_with(posts, &lemmy_url?(&1.activitypub_id))

    {mastodon_posts, activitypub_posts} =
      Enum.split_with(other_posts, &MastodonApi.is_mastodon_compatible?/1)

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

  defp refresh_lemmy_post(post, %{score: score, comments: comments}) do
    if counts_changed?(post, score, comments, 0) do
      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [
          like_count: max(score, post.like_count || 0),
          reply_count: max(comments, post.reply_count || 0),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
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

  defp refresh_mastodon_post(post, %{
         favourites_count: fav,
         reblogs_count: reb,
         replies_count: rep
       }) do
    if counts_changed?(post, fav, rep, reb) do
      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [
          like_count: max(fav, post.like_count || 0),
          reply_count: max(rep, post.reply_count || 0),
          share_count: max(reb, post.share_count || 0),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )
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
    case fetch_counts_smart(ap_id) do
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
      share_count: new_counts[:share_count] || new_counts[:reblogs_count] || 0
    }
  end

  defp maybe_update_refreshed_counts(post, id, ap_id, %{
         like_count: likes,
         reply_count: replies,
         share_count: shares
       }) do
    if counts_changed?(post, likes, replies, shares) do
      Repo.update_all(
        from(m in Message, where: m.id == ^id),
        set: [
          like_count: max(likes, post.like_count || 0),
          reply_count: max(replies, post.reply_count || 0),
          share_count: max(shares, post.share_count || 0),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      Logger.debug(
        "Refreshed counts for #{ap_id}: likes=#{likes}, replies=#{replies}, shares=#{shares}"
      )

      {:ok, %{like_count: likes, reply_count: replies, share_count: shares}}
    else
      {:ok,
       %{
         like_count: post.like_count,
         reply_count: post.reply_count,
         share_count: post.share_count
       }}
    end
  end

  # Intelligently fetch counts using the best available API for each platform
  defp fetch_counts_smart(ap_id) do
    cond do
      # Lemmy posts: use Lemmy API (most reliable)
      lemmy_url?(ap_id) ->
        case LemmyApi.fetch_post_counts(ap_id) do
          %{score: score, comments: comments} = counts ->
            {:ok, %{like_count: score, reply_count: comments, share_count: 0, raw: counts}}

          nil ->
            fetch_counts_activitypub(ap_id)
        end

      # Mastodon-compatible: use Mastodon API
      MastodonApi.is_mastodon_compatible?(%{activitypub_id: ap_id}) ->
        case MastodonApi.fetch_status_counts(ap_id) do
          %{favourites_count: fav, reblogs_count: reb, replies_count: rep} ->
            {:ok, %{like_count: fav, reply_count: rep, share_count: reb}}

          nil ->
            fetch_counts_activitypub(ap_id)
        end

      # Fallback: use ActivityPub
      true ->
        fetch_counts_activitypub(ap_id)
    end
  end

  defp fetch_counts_activitypub(ap_id) do
    case Fetcher.fetch_object(ap_id) do
      {:ok, object} ->
        {:ok,
         %{
           like_count: Helpers.extract_interaction_count(object, "likes"),
           reply_count: Helpers.extract_interaction_count(object, "replies"),
           share_count: Helpers.extract_interaction_count(object, "shares")
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lemmy_url?(url) when is_binary(url) do
    String.contains?(url, "/post/") or String.contains?(url, "/comment/")
  end

  defp lemmy_url?(_), do: false

  defp counts_changed?(post, new_likes, new_replies, new_shares) do
    (post.like_count || 0) != new_likes ||
      (post.reply_count || 0) != new_replies ||
      (post.share_count || 0) != new_shares
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
    ap_id = message.activitypub_id

    if MastodonApi.is_mastodon_compatible?(message) do
      # Mastodon API provides user info directly
      case MastodonApi.fetch_favourited_by(ap_id) do
        {:ok, accounts} -> {:ok, accounts}
        {:error, _} -> fetch_likers_activitypub(message)
      end
    else
      # Lemmy doesn't expose individual likers, fall back
      fetch_likers_activitypub(message)
    end
  end

  defp fetch_likers_activitypub(message) do
    case Fetcher.fetch_object(message.activitypub_id) do
      {:ok, object} ->
        likes_collection = object["likes"]

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
    ap_id = message.activitypub_id

    if MastodonApi.is_mastodon_compatible?(message) do
      # Mastodon API provides user info directly
      case MastodonApi.fetch_reblogged_by(ap_id) do
        {:ok, accounts} -> {:ok, accounts}
        {:error, _} -> fetch_sharers_activitypub(message)
      end
    else
      # Lemmy doesn't have boosts, fall back
      fetch_sharers_activitypub(message)
    end
  end

  defp fetch_sharers_activitypub(message) do
    case Fetcher.fetch_object(message.activitypub_id) do
      {:ok, object} ->
        shares_collection = object["shares"] || object["announces"]

        case CollectionFetcher.fetch_interaction_actors(shares_collection, max_items: 50) do
          {:ok, actors} -> {:ok, actors}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sets up periodic refresh jobs.
  Call this from application startup or a scheduler.
  """
  def setup_periodic_jobs do
    # Schedule jobs if not already running
    jobs = [
      # Refresh recent posts every hour
      %{"type" => "refresh_recent"},
      # Refresh popular posts every 4 hours
      %{"type" => "refresh_popular"},
      # Refresh interacted posts every 30 minutes
      %{"type" => "refresh_interacted"}
    ]

    Enum.each(jobs, fn args ->
      args
      |> new(unique: [period: 1800, keys: [:type]])
      |> Oban.insert()
    end)

    :ok
  end
end
