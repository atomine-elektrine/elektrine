defmodule Paige.Providers.DuckDuckGo do
  @moduledoc "Scrapes DuckDuckGo's HTML search surface for Paige."

  @behaviour Paige.Provider

  alias Paige.Result

  @default_endpoint "https://html.duckduckgo.com/html/"

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    with :ok <- acquire(opts),
         {:ok, body} <- fetch(url(query, opts), opts),
         :ok <- reject_block_page(body, opts),
         {:ok, document} <- Floki.parse_document(body),
         {:ok, results} <- parse_results(document, body, opts) do
      {:ok, results}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp acquire(opts) do
    if Keyword.has_key?(opts, :request_fun),
      do: :ok,
      else: Paige.ScraperThrottle.acquire(:duckduckgo, Keyword.get(opts, :min_interval_ms, 1_000))
  end

  defp fetch(url, opts) do
    case Paige.HTTP.get_text(url, headers(), opts) do
      {:error, {:rate_limited, retry_after}} = error ->
        Paige.ScraperThrottle.block(:duckduckgo, retry_after)
        error

      result ->
        result
    end
  end

  defp url(query, opts) do
    params =
      [
        q: query,
        s: page_offset(Keyword.get(opts, :page, 1)),
        kl: region(opts),
        kp: safesearch(Keyword.get(opts, :safesearch)),
        df: freshness(Keyword.get(opts, :freshness))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    String.trim_trailing(endpoint, "?") <> "?" <> URI.encode_query(params)
  end

  defp headers do
    [
      {"Accept", "text/html,application/xhtml+xml"},
      {"Accept-Language", "en-US,en;q=0.8"},
      {"User-Agent", user_agent()}
    ]
  end

  defp reject_block_page(body, opts) do
    normalized = String.downcase(body)

    if String.contains?(normalized, [
         "anomaly-modal",
         "challenge-form",
         "bots use duckduckgo",
         "verify you are a human"
       ]) do
      unless Keyword.has_key?(opts, :request_fun) do
        Paige.ScraperThrottle.block(:duckduckgo, 300)
      end

      {:error, :blocked}
    else
      :ok
    end
  end

  defp parse_results(document, body, opts) do
    results =
      document
      |> Floki.find(".result")
      |> Enum.with_index()
      |> Enum.flat_map(fn {node, index} -> parse_result(node, index) end)
      |> Enum.take(normalize_limit(Keyword.get(opts, :limit, 10)))

    cond do
      results != [] -> {:ok, results}
      String.contains?(String.downcase(body), "no results") -> {:ok, []}
      true -> {:error, :invalid_response}
    end
  end

  defp parse_result(node, index) do
    case Floki.find(node, "a.result__a") |> List.first() do
      nil ->
        []

      anchor ->
        title = anchor |> Floki.text(sep: " ") |> clean_text()
        url = anchor |> Floki.attribute("href") |> List.first() |> unwrap_result_url()

        if present?(title) and present?(url) do
          [
            %Result{
              title: title,
              url: url,
              snippet: snippet(node),
              source: "DuckDuckGo",
              score: 1_000 - index,
              metadata: %{provider: :duckduckgo, kind: :web}
            }
          ]
        else
          []
        end
    end
  end

  defp snippet(node) do
    node
    |> Floki.find(".result__snippet")
    |> List.first()
    |> case do
      nil -> nil
      snippet -> snippet |> Floki.text(sep: " ") |> clean_text() |> nil_if_empty()
    end
  end

  defp unwrap_result_url(nil), do: nil

  defp unwrap_result_url("//" <> path),
    do: unwrap_result_url("https://" <> path)

  defp unwrap_result_url(url) do
    case URI.parse(url) do
      %URI{host: host, path: "/l/", query: query}
      when host in ["duckduckgo.com", "www.duckduckgo.com"] ->
        query |> URI.decode_query() |> Map.get("uddg")

      _uri ->
        url
    end
  rescue
    _error -> nil
  end

  defp page_offset(page) when is_integer(page) and page > 1, do: (min(page, 10) - 1) * 30
  defp page_offset(_page), do: nil

  defp region(opts) do
    country = opts |> Keyword.get(:country, "us") |> normalized_code("us")
    language = opts |> Keyword.get(:search_lang, "en") |> normalized_code("en")
    "#{country}-#{language}"
  end

  defp normalized_code(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> default
      value -> value
    end
  end

  defp normalized_code(_value, default), do: default

  defp safesearch(value) when value in [:strict, "strict"], do: 1
  defp safesearch(value) when value in [:off, "off"], do: -2
  defp safesearch(_value), do: -1

  defp freshness(value) when value in [:day, "day", "pd"], do: "d"
  defp freshness(value) when value in [:week, "week", "pw"], do: "w"
  defp freshness(value) when value in [:month, "month", "pm"], do: "m"
  defp freshness(value) when value in [:year, "year", "py"], do: "y"
  defp freshness(_value), do: nil

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)
  defp normalize_limit(_limit), do: 10

  defp clean_text(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp user_agent, do: Application.get_env(:paige, :user_agent, "Paige/0.1")
end
