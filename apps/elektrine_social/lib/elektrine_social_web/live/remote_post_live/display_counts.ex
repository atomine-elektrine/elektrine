defmodule ElektrineSocialWeb.RemotePostLive.DisplayCounts do
  @moduledoc """
  Display-count math for locally mirrored remote posts.

  Combines local engagement counts, cached Lemmy counts, and optimistic UI
  deltas into the numbers the remote post surfaces render.
  """

  alias Elektrine.Social.EngagementCounts
  alias ElektrineSocialWeb.Components.Social.PostUtilities

  def local_message_display_like_count(message, lemmy_counts \\ nil, delta \\ 0)

  def local_message_display_like_count(message, lemmy_counts, delta) when is_map(message) do
    message
    |> PostUtilities.display_primary_count(lemmy_counts_for_message(message, lemmy_counts))
    |> Kernel.+(delta || 0)
    |> max(0)
  end

  def local_message_display_like_count(_, _, delta), do: max(delta || 0, 0)

  def local_message_display_share_count(message, delta)

  def local_message_display_share_count(message, delta) when is_map(message) do
    message
    |> PostUtilities.display_share_count()
    |> Kernel.+(delta || 0)
    |> max(0)
  end

  def local_message_display_share_count(_, delta), do: max(delta || 0, 0)

  def local_message_display_reply_count(message, lemmy_counts, loaded_replies)

  def local_message_display_reply_count(message, lemmy_counts, loaded_replies)
      when is_map(message) do
    PostUtilities.display_reply_count(
      message,
      lemmy_counts_for_message(message, lemmy_counts),
      loaded_replies
    )
  end

  def local_message_display_reply_count(_, _, loaded_replies) when is_list(loaded_replies),
    do: length(loaded_replies)

  def local_message_display_reply_count(_, _, _), do: 0

  @doc """
  Folds fresher platform counts into the local message.

  Returns `{updates, message}` where `updates` is the keyword list to persist
  and `message` reflects the merged counts.
  """
  def merge_platform_count_updates(local_message, counts) do
    display_fields = [
      :like_count,
      :reply_count,
      :share_count,
      :quote_count,
      :upvotes,
      :downvotes,
      :score
    ]

    {updates, message} =
      Enum.reduce(display_fields, {[], local_message}, fn field, {updates, message} ->
        platform_count = EngagementCounts.remote_count(Map.get(counts, field))
        current_count = Map.get(message, field, 0) || 0

        if platform_count > current_count do
          {[{field, platform_count} | updates], Map.put(message, field, platform_count)}
        else
          {updates, message}
        end
      end)

    remote_count_updates =
      [
        {:remote_like_count, :like_count},
        {:remote_reply_count, :reply_count},
        {:remote_share_count, :share_count},
        {:remote_quote_count, :quote_count}
      ]
      |> Enum.reduce([], fn {remote_field, count_field}, updates ->
        platform_count = EngagementCounts.remote_count(Map.get(counts, count_field))
        current_count = Map.get(message, remote_field, 0) || 0

        if platform_count > current_count do
          [{remote_field, platform_count} | updates]
        else
          updates
        end
      end)

    fetched_at = DateTime.utc_now() |> DateTime.truncate(:second)

    updates =
      if remote_count_updates != [] do
        [{:remote_counts_fetched_at, fetched_at} | remote_count_updates] ++ updates
      else
        updates
      end

    message =
      Enum.reduce(remote_count_updates, message, fn {field, value}, acc ->
        Map.put(acc, field, value)
      end)

    message =
      if remote_count_updates != [] do
        Map.put(message, :remote_counts_fetched_at, fetched_at)
      else
        message
      end

    {updates, message}
  end

  defp lemmy_counts_for_message(message, lemmy_counts)
       when is_map(message) and is_map(lemmy_counts) do
    cond do
      Map.has_key?(lemmy_counts, :score) or Map.has_key?(lemmy_counts, :upvotes) ->
        lemmy_counts

      is_binary(Map.get(message, :activitypub_id)) ->
        Map.get(lemmy_counts, Map.get(message, :activitypub_id))

      true ->
        nil
    end
  end

  defp lemmy_counts_for_message(_, _), do: nil
end
