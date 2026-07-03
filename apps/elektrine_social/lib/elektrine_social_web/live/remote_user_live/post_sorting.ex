defmodule ElektrineSocialWeb.RemoteUserLive.PostSorting do
  @moduledoc """
  Lemmy-style sorting and reply-chain grouping for remote profile posts.
  """

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias ElektrineSocialWeb.Components.Social.PostUtilities

  # Sorting functions for Lemmy-style post sorting
  def sort_posts(posts, sort_by) when is_list(posts) do
    posts = group_reply_chains(posts)

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

  def get_post_score(post) when is_map(post) do
    cached_primary_count = PostUtilities.display_primary_count(post)

    cond do
      PostUtilities.lemmy_vote_post?(post) &&
          (Map.has_key?(post, :upvotes) || Map.has_key?(post, :downvotes)) ->
        (post.upvotes || 0) - (post.downvotes || 0)

      PostUtilities.lemmy_vote_post?(post) &&
        Map.has_key?(post, :score) && post.score ->
        post.score

      cached_primary_count > 0 ->
        cached_primary_count

      # Local post with like_count only
      Map.has_key?(post, :like_count) && post.like_count ->
        post.like_count

      # Local post with score field (Ecto schema)
      Map.has_key?(post, :score) && post.score ->
        post.score

      # Outbox post - check for likes object with totalItems
      is_map(post["likes"]) ->
        APHelpers.get_collection_total(post["likes"])

      # Lemmy/ActivityPub posts might have comment count as activity indicator
      # Use replies count as a proxy for engagement when no vote counts available
      is_map(post["replies"]) ->
        APHelpers.get_collection_total(post["replies"])

      # Check for replies as a map with items
      is_map(post["comments"]) ->
        APHelpers.get_collection_total(post["comments"])

      true ->
        0
    end
  end

  defp group_reply_chains(posts) when is_list(posts) do
    ids_in_feed = MapSet.new(Enum.map(posts, &post_group_id/1))

    local_parent_ids =
      posts
      |> Enum.map(&Map.get(&1, :reply_to_id))
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()

    remote_parent_refs =
      posts
      |> Enum.map(&normalized_in_reply_to/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    thread_keys_by_id =
      Enum.reduce(posts, %{}, fn post, acc ->
        Map.put(
          acc,
          post_group_id(post),
          thread_group_key(post, ids_in_feed, local_parent_ids, remote_parent_refs)
        )
      end)

    posts
    |> Enum.group_by(fn post ->
      Map.get(thread_keys_by_id, post_group_id(post), {:post, post_group_id(post)})
    end)
    |> Enum.map(fn {_key, grouped_posts} -> choose_thread_representative(grouped_posts) end)
  end

  defp choose_thread_representative([post]), do: post

  defp choose_thread_representative(grouped_posts) do
    Enum.max_by(grouped_posts, &get_post_timestamp/1, fn -> List.first(grouped_posts) end)
  end

  defp thread_group_key(post, ids_in_feed, local_parent_ids, remote_parent_refs) do
    cond do
      is_integer(Map.get(post, :reply_to_id)) and
          MapSet.member?(ids_in_feed, Map.get(post, :reply_to_id)) ->
        {:local_thread, Map.get(post, :reply_to_id)}

      is_binary(normalized_in_reply_to(post)) ->
        {:remote_thread, normalized_in_reply_to(post)}

      MapSet.member?(local_parent_ids, Map.get(post, :id)) ->
        {:local_thread, post.id}

      matched_ref = Enum.find(thread_self_refs(post), &MapSet.member?(remote_parent_refs, &1)) ->
        {:remote_thread, matched_ref}

      true ->
        {:post, post_group_id(post)}
    end
  end

  defp thread_self_refs(post) do
    [Map.get(post, :activitypub_id), Map.get(post, :activitypub_url), map_string_key(post, "id")]
    |> Enum.map(&normalize_thread_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalized_in_reply_to(post) do
    cond do
      is_map_key(post, :media_metadata) ->
        post
        |> Map.get(:media_metadata, %{})
        |> get_in(["inReplyTo"])
        |> normalize_thread_ref()

      is_map(post) ->
        normalize_thread_ref(post["inReplyTo"])
    end
  end

  defp normalize_thread_ref(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_thread_ref(_), do: nil

  defp post_group_id(post) when is_map(post) do
    Map.get(post, :id) || map_string_key(post, "id")
  end

  defp post_group_id(_post), do: nil

  defp map_string_key(post, key) when is_map(post), do: Map.get(post, key)

  defp get_post_activity(post) when is_map(post) do
    cond do
      # Local post - use reply_count
      Map.has_key?(post, :reply_count) ->
        post.reply_count || 0

      # Outbox post - check for replies object
      is_map(post["replies"]) ->
        APHelpers.get_collection_total(post["replies"])

      true ->
        0
    end
  end
end
