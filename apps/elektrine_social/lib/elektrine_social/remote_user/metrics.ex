defmodule ElektrineSocial.RemoteUser.Metrics do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.ActivityPub.Actor
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
        AppCache.put_remote_user_community_stats(actor_id, stats)
        {:ok, stats}

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
    case AppCache.get_remote_user_community_stats(actor_id, fn -> %{members: 0, posts: 0} end) do
      {:ok, value} -> value
      _ -> %{members: 0, posts: 0}
    end
  end

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
          share_count: m.share_count
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
          share_count: m.share_count
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
              like_count: max(counts.score, post.like_count || 0),
              reply_count: max(counts.comments, post.reply_count || 0)
            ]

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

  defp get_follower_count(metadata) do
    case metadata["followers_count"] || metadata["followersCount"] do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, _} -> max(n, 0)
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp get_status_count(metadata) do
    case metadata["statuses_count"] || metadata["statusesCount"] || metadata["outbox_count"] do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, _} -> max(n, 0)
          :error -> 0
        end

      _ ->
        0
    end
  end
end
