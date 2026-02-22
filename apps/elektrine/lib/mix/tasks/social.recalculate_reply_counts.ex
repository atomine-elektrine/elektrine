defmodule Mix.Tasks.Social.RecalculateReplyCounts do
  @moduledoc """
  Recalculates reply_count for all timeline posts based on actual replies.

  Usage: mix social.recalculate_reply_counts
  """
  use Mix.Task
  import Ecto.Query
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  @shortdoc "Recalculates reply counts for all timeline posts"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("Recalculating reply counts for all posts (including nested)...")

    # Get all posts (not just timeline)
    posts =
      from(m in Message,
        where: m.post_type == "post",
        select: m.id
      )
      |> Repo.all()

    total = length(posts)
    IO.puts("Found #{total} posts to process...")

    # For each post, count all nested replies and update
    Enum.with_index(posts, 1)
    |> Enum.each(fn {post_id, index} ->
      # Count all replies including nested
      reply_count = count_nested_replies_recursive(post_id)

      # Update the count
      from(m in Message, where: m.id == ^post_id)
      |> Repo.update_all(set: [reply_count: reply_count])

      if rem(index, 100) == 0 do
        IO.puts("Processed #{index}/#{total} posts...")
      end
    end)

    IO.puts("Done! Recalculated reply counts for #{total} posts.")
  end

  # Count all replies including nested
  defp count_nested_replies_recursive(post_id) do
    # Get direct replies
    direct_reply_ids =
      from(m in Message,
        where: m.reply_to_id == ^post_id and is_nil(m.deleted_at),
        select: m.id
      )
      |> Repo.all()

    # Count direct + nested
    direct_count = length(direct_reply_ids)

    nested_count =
      Enum.reduce(direct_reply_ids, 0, fn reply_id, acc ->
        acc + count_nested_replies_recursive(reply_id)
      end)

    direct_count + nested_count
  end
end
