defmodule ElektrineSocial.RemoteUser.Metrics do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.ActivityPub.MastodonApi
  alias Elektrine.AppCache
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  def refresh_counts(actor_id) when is_integer(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{} = actor ->
        posts = local_posts_for_actor(actor)
        lemmy_counts = LemmyApi.fetch_posts_counts(posts)
        mastodon_counts = MastodonApi.fetch_statuses_counts(posts)

        update_posts_with_api_counts(posts, lemmy_counts, mastodon_counts)

        snapshot = %{lemmy_counts: lemmy_counts, mastodon_counts: mastodon_counts}
        AppCache.put_remote_user_counts(actor_id, snapshot)
        {:ok, snapshot}

      _ ->
        {:error, :actor_not_found}
    end
  end

  def refresh_community_stats(actor_id) when is_integer(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{actor_type: "Group"} = actor ->
        stats = fetch_group_stats(actor)
        cache_community_stats(actor, stats)

      _ ->
        {:error, :actor_not_found}
    end
  end

  def cached_counts(actor_id) when is_integer(actor_id) do
    case AppCache.get_remote_user_counts(actor_id, fn ->
           %{lemmy_counts: %{}, mastodon_counts: %{}}
         end) do
      {:ok, value} -> value
      _ -> %{lemmy_counts: %{}, mastodon_counts: %{}}
    end
  end

  def cached_community_stats(actor_id) when is_integer(actor_id) do
    persisted_stats = persisted_community_stats(actor_id)

    case AppCache.get_remote_user_community_stats(actor_id, fn -> persisted_stats end) do
      {:ok, value} -> merge_community_stats(persisted_stats, value)
      _ -> persisted_stats
    end
  end

  def cache_community_stats(%Actor{} = actor, stats) when is_map(stats) do
    persisted_stats = merge_community_stats(community_stats_from_actor(actor), stats)

    metadata =
      (actor.metadata || %{})
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("subscriber_count", persisted_stats.members)
      |> Map.put("posts_count", persisted_stats.posts)
      |> Map.put(
        "community_stats_fetched_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    case actor |> Actor.changeset(%{metadata: metadata}) |> Repo.update() do
      {:ok, _updated_actor} ->
        AppCache.put_remote_user_community_stats(actor.id, persisted_stats)
        {:ok, persisted_stats}

      {:error, _reason} ->
        AppCache.put_remote_user_community_stats(actor.id, persisted_stats)
        {:ok, persisted_stats}
    end
  end

  def cache_community_stats(_, _), do: {:error, :invalid_actor}

  defp local_posts_for_actor(%Actor{actor_type: "Group", uri: uri}) do
    Repo.all(
      from(m in Message,
        where: fragment("?->>'community_actor_uri' = ?", m.media_metadata, ^uri),
        where: is_nil(m.deleted_at),
        select: %{
          id: m.id,
          activitypub_id: m.activitypub_id,
          like_count: m.like_count,
          reply_count: m.reply_count,
          share_count: m.share_count,
          upvotes: m.upvotes,
          downvotes: m.downvotes,
          score: m.score
        }
      )
    )
  end

  defp local_posts_for_actor(%Actor{id: actor_id}) do
    Repo.all(
      from(m in Message,
        where: m.remote_actor_id == ^actor_id,
        where: is_nil(m.deleted_at),
        select: %{
          id: m.id,
          activitypub_id: m.activitypub_id,
          like_count: m.like_count,
          reply_count: m.reply_count,
          share_count: m.share_count,
          upvotes: m.upvotes,
          downvotes: m.downvotes,
          score: m.score
        }
      )
    )
  end

  defp update_posts_with_api_counts(posts, lemmy_counts, mastodon_counts) do
    Enum.each(posts, fn post ->
      ap_id = post.activitypub_id

      updates =
        cond do
          counts = Map.get(lemmy_counts, ap_id) ->
            [
              like_count: normalize_count(counts.score),
              reply_count: normalize_count(counts.comments),
              upvotes: normalize_count(counts.upvotes),
              downvotes: normalize_count(counts.downvotes),
              score: normalize_count(counts.score)
            ]

          counts = Map.get(mastodon_counts, ap_id) ->
            [
              like_count: normalize_count(counts.favourites_count),
              reply_count: normalize_count(counts.replies_count),
              share_count: normalize_count(counts.reblogs_count)
            ]

          true ->
            []
        end

      if updates != [] do
        Repo.update_all(
          from(m in Message, where: m.id == ^post.id),
          set: updates ++ [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )
      end
    end)
  end

  defp fetch_group_stats(%Actor{domain: domain, username: username, metadata: metadata}) do
    metadata = metadata || %{}
    metadata_stats = %{members: get_follower_count(metadata), posts: get_status_count(metadata)}
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
        Enum.max([metadata_stats.posts || 0, outbox_collection_count, lemmy_stats[:posts] || 0])
    }
  end

  defp fetch_collection_count(nil), do: 0

  defp fetch_collection_count(url) when is_binary(url) or is_map(url) do
    case Elektrine.ActivityPub.CollectionFetcher.fetch_collection_count(url) do
      {:ok, count} when is_integer(count) ->
        max(count, 0)

      {:ok, count} when is_binary(count) ->
        case Integer.parse(String.trim(count)) do
          {n, _} -> max(n, 0)
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp fetch_collection_count(_), do: 0

  defp persisted_community_stats(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{} = actor -> community_stats_from_actor(actor)
      _ -> %{members: 0, posts: 0}
    end
  end

  defp community_stats_from_actor(%Actor{metadata: metadata}) do
    %{
      members: get_follower_count(metadata || %{}),
      posts: get_status_count(metadata || %{})
    }
  end

  defp community_stats_from_actor(_), do: %{members: 0, posts: 0}

  defp merge_community_stats(current, incoming) do
    %{
      members: merged_count(current, incoming, :members),
      posts: merged_count(current, incoming, :posts)
    }
  end

  defp merged_count(current, incoming, key) do
    if has_count?(incoming, key) do
      incoming
      |> Map.get(key, Map.get(incoming, Atom.to_string(key)))
      |> normalize_count()
    else
      current
      |> Map.get(key, Map.get(current, Atom.to_string(key)))
      |> normalize_count()
    end
  end

  defp has_count?(stats, key) when is_map(stats) do
    Map.has_key?(stats, key) or Map.has_key?(stats, Atom.to_string(key))
  end

  defp has_count?(_, _), do: false

  defp normalize_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_count(_), do: 0

  defp get_follower_count(metadata), do: APHelpers.get_follower_count(metadata)

  defp get_status_count(metadata), do: APHelpers.get_status_count(metadata)
end
