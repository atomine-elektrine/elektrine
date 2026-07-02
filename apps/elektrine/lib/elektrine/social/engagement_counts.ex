defmodule Elektrine.Social.EngagementCounts do
  @moduledoc """
  Normalization helpers for local and remote engagement counters.

  Remote servers can report bogus or stale counters. Store their values separately,
  clamp them, and only merge them with locally durable interaction rows through
  explicit reconciliation code.
  """

  @max_remote_count 100_000_000

  @remote_fields [
    :remote_like_count,
    :remote_reply_count,
    :remote_share_count,
    :remote_quote_count
  ]

  def remote_fields, do: @remote_fields
  def max_remote_count, do: @max_remote_count

  def remote_count(value), do: non_negative_integer(value) |> min(@max_remote_count)

  def nullable_remote_count(value) do
    case remote_count(value) do
      0 -> nil
      count -> count
    end
  end

  def non_negative_integer(value) when is_integer(value), do: max(value, 0)

  def non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} -> max(count, 0)
      :error -> 0
    end
  end

  def non_negative_integer(_), do: 0
end
