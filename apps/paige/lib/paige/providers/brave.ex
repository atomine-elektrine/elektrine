defmodule Paige.Providers.Brave do
  @moduledoc "Brave Search API provider for Paige."

  @behaviour Paige.Provider

  alias Paige.Result

  @endpoints %{
    web: "https://api.search.brave.com/res/v1/web/search",
    images: "https://api.search.brave.com/res/v1/images/search",
    videos: "https://api.search.brave.com/res/v1/videos/search",
    news: "https://api.search.brave.com/res/v1/news/search"
  }

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    kind = result_kind(opts)

    with {:ok, endpoint} <- endpoint(kind),
         {:ok, api_key} <- api_key(opts),
         {:ok, payload} <- Paige.HTTP.get_json(url(endpoint, query, opts), headers(api_key), opts) do
      {:ok, parse_results(kind, payload)}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp api_key(opts) do
    key = Keyword.get(opts, :api_key) || Application.get_env(:paige, :brave_api_key)

    if present?(key), do: {:ok, key}, else: {:error, :missing_api_key}
  end

  defp result_kind(opts) do
    opts
    |> Keyword.get(:kind, :web)
    |> Paige.Kind.normalize()
  end

  defp endpoint(kind) do
    case Map.fetch(@endpoints, kind) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, :unsupported_kind}
    end
  end

  defp url(endpoint, query, opts) do
    count = opts |> Keyword.get(:limit, 10) |> clamp_limit(max_count(result_kind(opts)))

    query_string =
      %{
        q: query,
        count: count,
        country: Keyword.get(opts, :country, "us"),
        search_lang: Keyword.get(opts, :search_lang, "en"),
        spellcheck: Keyword.get(opts, :spellcheck, 1)
      }
      |> URI.encode_query()

    endpoint <> "?" <> query_string
  end

  defp headers(api_key) do
    [
      {"Accept", "application/json"},
      {"X-Subscription-Token", api_key}
    ]
  end

  defp parse_results(:web, %{"web" => %{"results" => results}}) when is_list(results) do
    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {result, index} -> parse_web_result(result, index) end)
  end

  defp parse_results(kind, %{"results" => results})
       when kind in [:images, :videos, :news] and is_list(results) do
    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {result, index} -> parse_vertical_result(kind, result, index) end)
  end

  defp parse_results(_kind, _payload), do: []

  defp parse_web_result(%{"title" => title, "url" => url} = result, index) do
    [
      %Result{
        title: title,
        url: url,
        snippet: text_value(result, ["description", "snippet"]),
        source: "Brave",
        score: 1_000 - index,
        metadata: %{provider: :brave, kind: :web}
      }
    ]
  end

  defp parse_web_result(_result, _index), do: []

  defp parse_vertical_result(kind, %{"title" => title} = result, index) do
    url = text_value(result, ["url", "page_url"])

    if present?(url) do
      [
        %Result{
          title: title,
          url: url,
          snippet: text_value(result, ["description", "snippet", "age"]),
          source: "Brave",
          score: 1_000 - index,
          metadata:
            %{
              provider: :brave,
              kind: kind,
              image_url: image_url(result),
              duration: text_value(result, ["duration"]),
              publisher: text_value(result, ["source", "publisher"])
            }
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new()
        }
      ]
    else
      []
    end
  end

  defp parse_vertical_result(_kind, _result, _index), do: []

  defp image_url(result) do
    text_value(result, ["thumbnail", "thumbnail_url", "image", "img"])
  end

  defp text_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> value
        %{"src" => value} when is_binary(value) -> value
        %{"url" => value} when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp clamp_limit(limit, max) when is_integer(limit), do: limit |> max(1) |> min(max)
  defp clamp_limit(_limit, _max), do: 10

  defp max_count(:images), do: 200
  defp max_count(:videos), do: 50
  defp max_count(:news), do: 50
  defp max_count(_kind), do: 20

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
