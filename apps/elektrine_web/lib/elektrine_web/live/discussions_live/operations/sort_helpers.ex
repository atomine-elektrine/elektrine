defmodule ElektrineWeb.DiscussionsLive.Operations.SortHelpers do
  @moduledoc """
  Shared helpers for community discussion sorting modes.
  """

  alias Elektrine.Messaging.Message
  alias Elektrine.Social

  @doc """
  Normalizes sort values from UI/legacy values to supported discussion sort modes.
  """
  def normalize_sort(sort) when is_binary(sort) do
    case sort do
      "score" -> "top"
      "recent" -> "new"
      "hot" -> "hot"
      "new" -> "new"
      "top" -> "top"
      "unanswered" -> "unanswered"
      _ -> "hot"
    end
  end

  def normalize_sort(_), do: "hot"

  @doc """
  Loads community posts for the given sort mode and applies client-side filtering
  for modes that are not directly represented in the DB query.
  """
  def load_posts(community_id, sort, opts \\ []) do
    normalized_sort = normalize_sort(sort)
    limit = Keyword.get(opts, :limit, 20)

    posts =
      Social.get_discussion_posts(community_id,
        limit: limit,
        sort_by: db_sort_for(normalized_sort)
      )
      |> Enum.map(&Message.decrypt_content/1)

    apply_post_filter(posts, normalized_sort)
  end

  defp db_sort_for("top"), do: "score"
  defp db_sort_for("new"), do: "recent"
  defp db_sort_for("unanswered"), do: "recent"
  defp db_sort_for("hot"), do: "hot"
  defp db_sort_for(_), do: "hot"

  defp apply_post_filter(posts, "unanswered") do
    Enum.filter(posts, fn post ->
      (post.reply_count || 0) == 0
    end)
  end

  defp apply_post_filter(posts, _), do: posts
end
