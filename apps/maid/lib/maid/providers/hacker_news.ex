defmodule Maid.Providers.HackerNews do
  @moduledoc "Hacker News Algolia provider for Maid."

  @behaviour Maid.Provider

  alias Maid.Result

  @endpoint "https://hn.algolia.com/api/v1/search"

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    case Maid.HTTP.get_json(url(query, opts), headers(), opts) do
      {:ok, payload} -> {:ok, parse_results(payload)}
      {:error, reason} -> {:error, reason}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp url(query, opts) do
    limit = opts |> Keyword.get(:limit, 10) |> clamp_limit(50)

    query_string =
      URI.encode_query(%{
        query: query,
        tags: "story",
        hitsPerPage: limit
      })

    @endpoint <> "?" <> query_string
  end

  defp headers, do: [{"Accept", "application/json"}]

  defp parse_results(%{"hits" => hits}) when is_list(hits) do
    Enum.flat_map(hits, &parse_hit/1)
  end

  defp parse_results(_payload), do: []

  defp parse_hit(%{"objectID" => object_id} = hit) do
    title = first_present(hit, ["title", "story_title"])

    url =
      first_present(hit, ["url", "story_url"]) ||
        "https://news.ycombinator.com/item?id=#{object_id}"

    if present?(title) do
      [
        %Result{
          title: title,
          url: url,
          snippet: comment_url(object_id, hit),
          source: "Hacker News",
          score: score(hit),
          published_at: parse_datetime(Map.get(hit, "created_at")),
          metadata: %{provider: :hacker_news, object_id: object_id}
        }
      ]
    else
      []
    end
  end

  defp parse_hit(_hit), do: []

  defp comment_url(object_id, _hit),
    do: "HN discussion: https://news.ycombinator.com/item?id=#{object_id}"

  defp score(hit) do
    (Map.get(hit, "points") || 0) + (Map.get(hit, "num_comments") || 0) / 10
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      value = Map.get(map, key)
      if present?(value), do: value
    end)
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp clamp_limit(limit, max) when is_integer(limit), do: limit |> max(1) |> min(max)
  defp clamp_limit(_limit, _max), do: 10

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
