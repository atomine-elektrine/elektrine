defmodule Elektrine.Social.MessageStats do
  @moduledoc """
  Write helpers for the `social_message_stats` counter table.
  """

  alias Elektrine.Repo
  alias Elektrine.Social.{EngagementCounts, MessageStat}

  @count_fields [:like_count, :reply_count, :share_count, :quote_count]

  def upsert_counts(message_id, counts) when is_integer(message_id) and is_map(counts) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    count_attrs = normalize_counts(counts)
    remote_attrs = normalize_remote_counts(counts)
    fetched_attrs = remote_fetched_at_attrs(counts)

    attrs =
      %{
        message_id: message_id,
        like_count: 0,
        reply_count: 0,
        share_count: 0,
        quote_count: 0,
        inserted_at: now,
        updated_at: now
      }
      |> Map.merge(count_attrs)
      |> Map.merge(remote_attrs)
      |> Map.merge(fetched_attrs)

    conflict_set =
      count_attrs
      |> Map.merge(remote_attrs)
      |> Map.merge(fetched_attrs)
      |> Map.put(:updated_at, now)
      |> Map.to_list()

    if conflict_set == [updated_at: now] do
      :ok
    else
      Repo.insert_all(MessageStat, [attrs],
        on_conflict: [set: conflict_set],
        conflict_target: [:message_id]
      )
    end

    :ok
  end

  def upsert_counts(_message_id, _counts), do: :ok

  defp normalize_counts(counts) do
    @count_fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(counts, field) do
        value when not is_nil(value) ->
          Map.put(acc, field, EngagementCounts.non_negative_integer(value))

        nil ->
          acc
      end
    end)
  end

  defp normalize_remote_counts(counts) do
    EngagementCounts.remote_fields()
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(counts, field) do
        value when not is_nil(value) ->
          Map.put(acc, field, EngagementCounts.nullable_remote_count(value))

        nil ->
          acc
      end
    end)
  end

  defp remote_fetched_at_attrs(%{remote_counts_fetched_at: fetched_at})
       when not is_nil(fetched_at) do
    %{remote_counts_fetched_at: fetched_at}
  end

  defp remote_fetched_at_attrs(_), do: %{}
end
