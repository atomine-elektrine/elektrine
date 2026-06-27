defmodule ElektrineSocialWeb.RemotePostLive.Counts do
  @moduledoc false

  def cached_reply_count(msg) do
    metadata = msg.media_metadata || %{}

    [
      normalize_cached_reply_count(msg.reply_count),
      normalize_cached_reply_count(metadata["original_reply_count"]),
      normalize_cached_reply_count(metadata["reply_count"]),
      normalize_cached_reply_count(metadata["replies_count"]),
      normalize_cached_reply_count(total_items_from_collection(metadata["replies"])),
      normalize_cached_reply_count(total_items_from_collection(metadata["comments"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  def total_items_from_collection(collection) when is_map(collection) do
    Map.get(collection, "totalItems") || Map.get(collection, :totalItems)
  end

  def total_items_from_collection(_), do: nil

  def apply_counts_to_post_object(nil, _counts), do: nil

  def apply_counts_to_post_object(post, counts) when is_map(post) do
    like_count = Map.get(counts, :like_count)
    reply_count = Map.get(counts, :reply_count)
    share_count = Map.get(counts, :share_count)
    quote_count = Map.get(counts, :quote_count)

    post
    |> maybe_put_collection_total("likes", like_count)
    |> maybe_put_collection_total("replies", reply_count)
    |> maybe_put_collection_total("shares", share_count)
    |> maybe_put_optional_count("like_count", like_count)
    |> maybe_put_optional_count("reply_count", reply_count)
    |> maybe_put_optional_count("share_count", share_count)
    |> maybe_put_optional_count("quotes_count", quote_count)
    |> maybe_put_optional_count("upvotes", Map.get(counts, :upvotes))
    |> maybe_put_optional_count("downvotes", Map.get(counts, :downvotes))
    |> maybe_put_optional_count("score", Map.get(counts, :score))
  end

  def apply_status_metadata_to_post_object(post, metadata)
      when is_map(post) and is_map(metadata) do
    metadata
    |> Enum.reduce(post, fn
      {key, value}, acc
      when key in [
             "emoji_reactions",
             "quotes_count",
             "quote",
             "quote_id",
             "quote_url",
             "card",
             "application",
             "language",
             "media_attachments",
             "pleroma"
           ] ->
        maybe_put_status_metadata_field(acc, key, value)

      _, acc ->
        acc
    end)
  end

  def apply_status_metadata_to_post_object(post, _metadata), do: post

  def put_collection_total(nil, total), do: %{"type" => "Collection", "totalItems" => total}

  def put_collection_total(collection, total) when is_map(collection) do
    collection
    |> Map.put("totalItems", total)
    |> Map.put(:totalItems, total)
  end

  def put_collection_total(_collection, total), do: total

  def cached_replies_object(msg, replies_count) do
    metadata = msg.media_metadata || %{}

    cond do
      is_map(metadata["replies"]) ->
        Map.put_new(metadata["replies"], "totalItems", replies_count)

      is_binary(metadata["replies_url"]) ->
        %{"id" => metadata["replies_url"], "totalItems" => replies_count}

      replies_count > 0 ->
        %{"totalItems" => replies_count}

      true ->
        nil
    end
  end

  def cached_comments_object(msg, replies_count) do
    metadata = msg.media_metadata || %{}

    cond do
      is_map(metadata["comments"]) ->
        Map.put_new(metadata["comments"], "totalItems", replies_count)

      is_binary(metadata["comments_url"]) ->
        %{"id" => metadata["comments_url"], "totalItems" => replies_count}

      true ->
        nil
    end
  end

  def normalize_cached_reply_count(value) when is_integer(value), do: max(value, 0)

  def normalize_cached_reply_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  def normalize_cached_reply_count(_), do: 0

  defp maybe_put_status_metadata_field(post, _key, nil), do: post
  defp maybe_put_status_metadata_field(post, _key, []), do: post

  defp maybe_put_status_metadata_field(post, _key, %{} = value) when map_size(value) == 0,
    do: post

  defp maybe_put_status_metadata_field(post, key, value), do: Map.put(post, key, value)

  defp maybe_put_collection_total(post, _key, total)
       when not is_map(post) or not is_integer(total),
       do: post

  defp maybe_put_collection_total(post, key, total) do
    Map.put(post, key, put_collection_total(Map.get(post, key), total))
  end

  defp maybe_put_optional_count(post, _key, value)
       when not is_map(post) or not is_integer(value),
       do: post

  defp maybe_put_optional_count(post, key, value), do: Map.put(post, key, value)
end
