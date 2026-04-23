defmodule Elektrine.ActivityPub.LemmyCommentBackfill do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages

  @spec run(keyword()) :: %{posts: non_neg_integer(), comments: non_neg_integer()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    lemmy_posts = list_lemmy_posts()

    remote_comments_updated =
      Enum.reduce(lemmy_posts, 0, fn post, acc ->
        acc + backfill_post_comments(post, dry_run?: dry_run?)
      end)

    fallback_comments_updated = backfill_upvotes_from_like_count(dry_run?: dry_run?)

    %{
      posts: length(lemmy_posts),
      comments: remote_comments_updated + fallback_comments_updated,
      remote_comments: remote_comments_updated,
      fallback_comments: fallback_comments_updated
    }
  end

  @spec backfill_post_comments(Message.t(), keyword()) :: non_neg_integer()
  def backfill_post_comments(%Message{} = post, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    fetcher = Keyword.get(opts, :fetcher, &LemmyApi.fetch_comment_counts/1)

    post
    |> lemmy_post_ref()
    |> fetcher.()
    |> apply_comment_counts(dry_run?: dry_run?)
  end

  @spec apply_comment_counts(map(), keyword()) :: non_neg_integer()
  def apply_comment_counts(comment_counts, opts \\ [])

  def apply_comment_counts(comment_counts, opts) when is_map(comment_counts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    ap_ids = Map.keys(comment_counts)

    if ap_ids == [] do
      0
    else
      Message
      |> where([m], m.activitypub_id in ^ap_ids)
      |> Repo.all()
      |> Enum.reduce(0, fn message, acc ->
        counts = Map.get(comment_counts, message.activitypub_id, %{})

        if comment_counts_changed?(message, counts) do
          unless dry_run? do
            persist_comment_counts(message, counts)
          end

          acc + 1
        else
          acc
        end
      end)
    end
  end

  def apply_comment_counts(_, _), do: 0

  @spec backfill_upvotes_from_like_count(keyword()) :: non_neg_integer()
  def backfill_upvotes_from_like_count(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    Message
    |> where(
      [m],
      fragment("? LIKE '%/comment/%'", m.activitypub_id) or
        fragment("? LIKE '%/comment/%'", m.activitypub_url)
    )
    |> where([m], m.upvotes == 0 and m.like_count > 0)
    |> Repo.all()
    |> Enum.reduce(0, fn message, acc ->
      unless dry_run? do
        Repo.update_all(
          from(m in Message, where: m.id == ^message.id),
          set: [
            upvotes: message.like_count,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        Messages.broadcast_post_counts_updated(message.id, %{
          like_count: message.like_count,
          reply_count: message.reply_count || 0,
          share_count: message.share_count || 0
        })
      end

      acc + 1
    end)
  end

  defp list_lemmy_posts do
    Message
    |> join(:inner, [p], r in Message, on: r.reply_to_id == p.id)
    |> where([p, _r], is_nil(p.reply_to_id))
    |> where([p, _r], not is_nil(p.activitypub_id))
    |> distinct([p, _r], true)
    |> select([p, _r], p)
    |> Repo.all()
    |> Enum.filter(fn post ->
      LemmyApi.community_post_url?(post.activitypub_id || post.activitypub_url)
    end)
  end

  defp lemmy_post_ref(%Message{activitypub_id: activitypub_id}) when is_binary(activitypub_id),
    do: activitypub_id

  defp lemmy_post_ref(%Message{activitypub_url: activitypub_url}) when is_binary(activitypub_url),
    do: activitypub_url

  defp lemmy_post_ref(_), do: nil

  defp comment_counts_changed?(message, counts) do
    message.like_count != normalized_count(counts, :upvotes) ||
      message.upvotes != normalized_count(counts, :upvotes) ||
      message.downvotes != normalized_count(counts, :downvotes) ||
      message.score != normalized_count(counts, :score) ||
      message.reply_count != normalized_count(counts, :child_count)
  end

  defp persist_comment_counts(message, counts) do
    updated_counts = %{
      like_count: normalized_count(counts, :upvotes),
      upvotes: normalized_count(counts, :upvotes),
      downvotes: normalized_count(counts, :downvotes),
      score: normalized_count(counts, :score),
      reply_count: normalized_count(counts, :child_count),
      share_count: message.share_count || 0
    }

    Repo.update_all(
      from(m in Message, where: m.id == ^message.id),
      set: [
        like_count: updated_counts.like_count,
        upvotes: updated_counts.upvotes,
        downvotes: updated_counts.downvotes,
        score: updated_counts.score,
        reply_count: updated_counts.reply_count,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    Messages.broadcast_post_counts_updated(message.id, updated_counts)
  end

  defp normalized_count(counts, key) do
    case Map.get(counts, key, 0) do
      value when is_integer(value) -> max(value, 0)
      _ -> 0
    end
  end
end
