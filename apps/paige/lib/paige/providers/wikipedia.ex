defmodule Paige.Providers.Wikipedia do
  @moduledoc "Wikipedia search provider for Paige."

  @behaviour Paige.Provider

  alias Paige.Result

  @endpoint "https://en.wikipedia.org/w/api.php"

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
    limit = opts |> Keyword.get(:limit, 5) |> clamp_limit(20)
    offset = (normalize_page(Keyword.get(opts, :page, 1)) - 1) * limit

    query_string =
      URI.encode_query(%{
        action: "query",
        format: "json",
        list: "search",
        srsearch: query,
        srlimit: limit,
        sroffset: offset,
        utf8: 1
      })

    @endpoint <> "?" <> query_string
  end

  defp headers, do: [{"Accept", "application/json"}, {"User-Agent", user_agent()}]

  defp parse_results(%{"query" => %{"search" => results}}) when is_list(results) do
    {:ok, Enum.flat_map(results, &parse_result/1)}
  end

  defp parse_results(_payload), do: {:error, :invalid_response}

  defp parse_result(%{"title" => title} = result) when is_binary(title) do
    [
      %Result{
        title: title,
        url: "https://en.wikipedia.org/wiki/" <> URI.encode(String.replace(title, " ", "_")),
        snippet: result |> Map.get("snippet") |> strip_html(),
        source: "Wikipedia",
        score: numeric_value(Map.get(result, "size")),
        metadata: %{provider: :wikipedia, page_id: Map.get(result, "pageid")}
      }
    ]
  end

  defp parse_result(_result), do: []

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_value), do: 0

  defp strip_html(nil), do: nil

  defp strip_html(value) when is_binary(value) do
    value
    |> html_unescape()
    |> String.replace(~r/<[^>]*>/, "")
    |> html_unescape()
  end

  defp strip_html(_value), do: nil

  defp html_unescape(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#039;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp clamp_limit(limit, max) when is_integer(limit), do: limit |> max(1) |> min(max)
  defp clamp_limit(_limit, _max), do: 5

  defp normalize_page(page) when is_integer(page), do: page |> max(1) |> min(10)

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(String.trim(page)) do
      {parsed, ""} -> normalize_page(parsed)
      _error -> 1
    end
  end

  defp normalize_page(_page), do: 1

  defp user_agent, do: Application.get_env(:paige, :user_agent, "Paige/0.1")
end
