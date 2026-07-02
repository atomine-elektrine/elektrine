defmodule Elektrine.Social.EngagementCountRepair do
  @moduledoc """
  Repairs cached social engagement counters from durable local rows and remote baselines.
  """

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.{EngagementCounts, Message, PostBoost, PostLike}

  @type result :: %{seen: non_neg_integer(), changed: non_neg_integer()}

  @doc """
  Repairs social message counters in keyset batches.

  Options:

    * `:dry_run` - scan and report changes without writing
    * `:limit` - maximum messages to inspect
    * `:batch_size` - number of messages per query, defaults to 500
    * `:progress_fun` - optional function called with the running result
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)
    batch_size = Keyword.get(opts, :batch_size, 500)
    progress_fun = Keyword.get(opts, :progress_fun)

    repair_batches(%{seen: 0, changed: 0, last_id: 0}, limit, batch_size, dry_run?, progress_fun)
    |> Map.delete(:last_id)
  end

  defp repair_batches(acc, limit, batch_size, dry_run?, progress_fun) do
    remaining =
      case limit do
        nil -> batch_size
        limit -> min(batch_size, max(limit - acc.seen, 0))
      end

    if remaining <= 0 do
      acc
    else
      batch =
        from(m in Message,
          where: m.id > ^acc.last_id,
          order_by: [asc: m.id],
          limit: ^remaining
        )
        |> Repo.all()

      case batch do
        [] ->
          acc

        messages ->
          next_acc =
            Enum.reduce(messages, acc, fn message, acc ->
              changed? = repair_message(message, dry_run?)

              %{
                acc
                | seen: acc.seen + 1,
                  changed: acc.changed + if(changed?, do: 1, else: 0),
                  last_id: message.id
              }
            end)

          if is_function(progress_fun, 1) and rem(next_acc.seen, batch_size * 10) == 0 do
            progress_fun.(Map.delete(next_acc, :last_id))
          end

          repair_batches(next_acc, limit, batch_size, dry_run?, progress_fun)
      end
    end
  end

  defp repair_message(%Message{} = message, dry_run?) do
    remote_like_count = remote_count(message, :remote_like_count, "original_like_count")
    remote_reply_count = remote_count(message, :remote_reply_count, "original_reply_count")
    remote_share_count = remote_count(message, :remote_share_count, "original_share_count")
    remote_quote_count = remote_count(message, :remote_quote_count, "quotes_count")

    local_like_count = local_like_count(message)
    local_reply_count = local_reply_count(message)
    local_share_count = local_share_count(message)

    attrs = %{
      remote_like_count: nullable_remote_count(remote_like_count),
      remote_reply_count: nullable_remote_count(remote_reply_count),
      remote_share_count: nullable_remote_count(remote_share_count),
      remote_quote_count: nullable_remote_count(remote_quote_count),
      like_count: known_count(message.like_count, remote_like_count, local_like_count),
      reply_count: known_count(message.reply_count, remote_reply_count, local_reply_count),
      share_count: known_count(message.share_count, remote_share_count, local_share_count),
      quote_count: max(message.quote_count || 0, remote_quote_count)
    }

    attrs =
      attrs
      |> Enum.reject(fn {field, value} -> Map.get(message, field) == value end)
      |> Map.new()

    if map_size(attrs) > 0 do
      unless dry_run? do
        from(m in Message, where: m.id == ^message.id)
        |> Repo.update_all(
          set: Map.put(attrs, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
        )
      end

      true
    else
      false
    end
  end

  defp remote_count(message, field, metadata_key) do
    max(
      non_negative_integer(Map.get(message, field)),
      non_negative_integer(Map.get(message.media_metadata || %{}, metadata_key))
    )
  end

  defp nullable_remote_count(count), do: EngagementCounts.nullable_remote_count(count)

  defp known_count(current_count, remote_count, local_count) do
    Enum.max([current_count || 0, remote_count + local_count, local_count, remote_count])
  end

  defp local_like_count(%Message{id: message_id, remote_counts_fetched_at: nil}) do
    from(l in PostLike, where: l.message_id == ^message_id, select: count(l.id))
    |> Repo.one()
  end

  defp local_like_count(%Message{id: message_id, remote_counts_fetched_at: fetched_at}) do
    from(l in PostLike,
      where: l.message_id == ^message_id and (is_nil(l.created_at) or l.created_at > ^fetched_at),
      select: count(l.id)
    )
    |> Repo.one()
  end

  defp local_reply_count(%Message{id: message_id, remote_counts_fetched_at: nil}) do
    from(m in Message,
      where: m.reply_to_id == ^message_id and is_nil(m.deleted_at),
      select: count(m.id)
    )
    |> Repo.one()
  end

  defp local_reply_count(%Message{id: message_id, remote_counts_fetched_at: fetched_at}) do
    fetched_at = DateTime.to_naive(fetched_at)

    from(m in Message,
      where:
        m.reply_to_id == ^message_id and is_nil(m.deleted_at) and
          (is_nil(m.inserted_at) or m.inserted_at > ^fetched_at),
      select: count(m.id)
    )
    |> Repo.one()
  end

  defp local_share_count(%Message{id: message_id, remote_counts_fetched_at: nil}) do
    from(b in PostBoost, where: b.message_id == ^message_id, select: count(b.id))
    |> Repo.one()
  end

  defp local_share_count(%Message{id: message_id, remote_counts_fetched_at: fetched_at}) do
    fetched_at = DateTime.to_naive(fetched_at)

    from(b in PostBoost,
      where:
        b.message_id == ^message_id and (is_nil(b.inserted_at) or b.inserted_at > ^fetched_at),
      select: count(b.id)
    )
    |> Repo.one()
  end

  defp non_negative_integer(value), do: EngagementCounts.remote_count(value)
end
