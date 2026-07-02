defmodule Elektrine.ActivityPub.ReplyFetchPolicy do
  @moduledoc """
  Central safety limits for remote reply ingestion.
  """

  @preview_max_replies 5
  @preview_max_depth 3
  @preview_max_pages 10
  @full_thread_max_replies 1_000
  @full_thread_max_depth 5
  @full_thread_max_pages 500
  @collection_max_replies 5
  @context_max_replies 5
  @cooldown_seconds 15 * 60
  @metadata_fetched_at_key "remote_replies_fetched_at"

  def preview_defaults do
    [
      max_replies: @preview_max_replies,
      max_depth: @preview_max_depth,
      max_pages: @preview_max_pages
    ]
  end

  def full_thread_defaults do
    [
      max_replies: @full_thread_max_replies,
      max_depth: @full_thread_max_depth,
      max_pages: @full_thread_max_pages
    ]
  end

  def clamp_fetch_opts(opts, mode \\ :preview) when is_list(opts) do
    defaults = if mode == :full_thread, do: full_thread_defaults(), else: preview_defaults()

    defaults
    |> Keyword.merge(opts)
    |> Keyword.update!(:max_replies, &clamp_positive(&1, Keyword.fetch!(defaults, :max_replies)))
    |> Keyword.update!(:max_depth, &clamp_positive(&1, Keyword.fetch!(defaults, :max_depth)))
    |> Keyword.update!(:max_pages, &clamp_positive(&1, Keyword.fetch!(defaults, :max_pages)))
  end

  def clamp_collection_limit(limit), do: clamp_positive(limit, @collection_max_replies)
  def clamp_context_limit(limit), do: clamp_positive(limit, @context_max_replies)

  def cooldown_seconds, do: @cooldown_seconds

  def fetched_at_metadata_key, do: @metadata_fetched_at_key

  def cooldown_elapsed?(message, opts \\ [])

  def cooldown_elapsed?(%{media_metadata: metadata}, opts)
      when is_map(metadata) and is_list(opts) do
    if Keyword.get(opts, :skip_cooldown, false) do
      true
    else
      metadata
      |> Map.get(@metadata_fetched_at_key)
      |> cooldown_elapsed_since?()
    end
  end

  def cooldown_elapsed?(%{media_metadata: nil}, opts)
      when is_list(opts),
      do: true

  def cooldown_elapsed?(_message, opts) when is_list(opts) do
    Keyword.get(opts, :skip_cooldown, false)
  end

  def cooldown_elapsed?(_message, _opts), do: true

  def fetched_at_timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def same_host?(left, right) when is_binary(left) and is_binary(right) do
    host(left) == host(right)
  end

  def same_host?(_, _), do: false

  def same_host_reply?(root_ref, reply) when is_binary(root_ref) and is_map(reply) do
    root_host = host(root_ref)
    reply_host = host(reply["id"]) || host(reply["url"])
    parent_host = host(reply["inReplyTo"])

    is_binary(root_host) and (reply_host == root_host or parent_host == root_host)
  end

  def same_host_reply?(_, _), do: false

  def filter_same_host_replies(replies, root_ref) when is_list(replies) and is_binary(root_ref) do
    Enum.filter(replies, &same_host_reply?(root_ref, &1))
  end

  def filter_same_host_replies(replies, _), do: replies

  defp clamp_positive(value, max_value) do
    value
    |> Elektrine.Social.EngagementCounts.non_negative_integer()
    |> min(max_value)
  end

  defp cooldown_elapsed_since?(nil), do: true
  defp cooldown_elapsed_since?(""), do: true

  defp cooldown_elapsed_since?(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, fetched_at, _offset} ->
        DateTime.diff(DateTime.utc_now(), fetched_at, :second) >= @cooldown_seconds

      _ ->
        true
    end
  end

  defp cooldown_elapsed_since?(_), do: true

  defp host(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp host(_), do: nil
end
