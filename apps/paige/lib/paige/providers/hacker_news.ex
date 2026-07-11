defmodule Paige.Providers.HackerNews do
  @moduledoc "Hacker News Algolia provider for Paige."

  @behaviour Paige.Provider

  alias Paige.Result

  @endpoint "https://hn.algolia.com/api/v1/search"

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    case Paige.HTTP.get_json(url(query, opts), headers(), opts) do
      {:ok, payload} -> parse_results(payload)
      {:error, reason} -> {:error, reason}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp url(query, opts) do
    limit = opts |> Keyword.get(:limit, 10) |> clamp_limit(50)
    page = normalize_page(Keyword.get(opts, :page, 1)) - 1

    query_string =
      URI.encode_query(%{
        query: query,
        tags: "story",
        hitsPerPage: limit,
        page: page
      })

    @endpoint <> "?" <> query_string
  end

  defp headers, do: [{"Accept", "application/json"}]

  defp parse_results(%{"hits" => hits}) when is_list(hits) do
    {:ok, Enum.flat_map(hits, &parse_hit/1)}
  end

  defp parse_results(_payload), do: {:error, :invalid_response}

  defp parse_hit(%{"objectID" => object_id} = hit) when is_binary(object_id) do
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
    numeric_value(Map.get(hit, "points")) + numeric_value(Map.get(hit, "num_comments")) / 10
  end

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_value), do: 0

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

  defp normalize_page(page) when is_integer(page), do: page |> max(1) |> min(10)

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(String.trim(page)) do
      {parsed, ""} -> normalize_page(parsed)
      _error -> 1
    end
  end

  defp normalize_page(_page), do: 1

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
