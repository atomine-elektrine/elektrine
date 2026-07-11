defmodule Paige.Providers.Wiby do
  @moduledoc "Scrapes Wiby's server-rendered web search results for Paige."

  @behaviour Paige.Provider

  alias Paige.Result

  @default_endpoint "https://wiby.me/"

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    with :ok <- acquire(opts),
         {:ok, body} <- fetch(url(query, opts), opts),
         {:ok, document} <- Floki.parse_document(body),
         {:ok, results} <- parse_results(document, opts) do
      {:ok, results}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp acquire(opts) do
    if Keyword.has_key?(opts, :request_fun),
      do: :ok,
      else: Paige.ScraperThrottle.acquire(:wiby, Keyword.get(opts, :min_interval_ms, 500))
  end

  defp fetch(url, opts) do
    case Paige.HTTP.get_text(url, headers(), opts) do
      {:error, {:rate_limited, retry_after}} = error ->
        Paige.ScraperThrottle.block(:wiby, retry_after)
        error

      result ->
        result
    end
  end

  defp url(query, opts) do
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)

    query_string =
      URI.encode_query(%{
        q: query,
        p: normalize_page(Keyword.get(opts, :page, 1))
      })

    String.trim_trailing(endpoint, "?") <> "?" <> query_string
  end

  defp headers do
    [
      {"Accept", "text/html,application/xhtml+xml"},
      {"User-Agent", user_agent()}
    ]
  end

  defp parse_results(document, opts) do
    results =
      document
      |> Floki.find("blockquote")
      |> Enum.with_index()
      |> Enum.flat_map(fn {node, index} -> parse_result(node, index) end)
      |> Enum.take(normalize_limit(Keyword.get(opts, :limit, 10)))

    if results != [] or valid_results_page?(document),
      do: {:ok, results},
      else: {:error, :invalid_response}
  end

  defp parse_result(node, index) do
    case Floki.find(node, "a.tlink") |> List.first() do
      nil ->
        []

      anchor ->
        title = anchor |> Floki.text(sep: " ") |> clean_text()
        url = Floki.attribute(anchor, "href") |> List.first()

        if present?(title) and present?(url) do
          [
            %Result{
              title: title,
              url: url,
              snippet: result_snippet(node),
              source: "Wiby",
              score: 1_000 - index,
              metadata: %{provider: :wiby, kind: :web}
            }
          ]
        else
          []
        end
    end
  end

  defp result_snippet(node) do
    node
    |> Floki.find("p")
    |> Enum.reject(fn paragraph -> "url" in Floki.attribute(paragraph, "class") end)
    |> List.first()
    |> case do
      nil -> nil
      paragraph -> paragraph |> Floki.text(sep: " ") |> clean_text() |> nil_if_empty()
    end
  end

  defp valid_results_page?(document),
    do: Floki.find(document, ~s(form input[name="q"])) != []

  defp normalize_page(page) when is_integer(page), do: page |> max(1) |> min(10)
  defp normalize_page(_page), do: 1

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)
  defp normalize_limit(_limit), do: 10

  defp clean_text(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp user_agent, do: Application.get_env(:paige, :user_agent, "Paige/0.1")
end
