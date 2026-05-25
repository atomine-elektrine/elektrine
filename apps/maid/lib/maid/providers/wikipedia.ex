defmodule Maid.Providers.Wikipedia do
  @moduledoc "Wikipedia search provider for Maid."

  @behaviour Maid.Provider

  alias Maid.Result

  @endpoint "https://en.wikipedia.org/w/api.php"

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
    limit = opts |> Keyword.get(:limit, 5) |> clamp_limit(20)

    query_string =
      URI.encode_query(%{
        action: "query",
        format: "json",
        list: "search",
        srsearch: query,
        srlimit: limit,
        utf8: 1
      })

    @endpoint <> "?" <> query_string
  end

  defp headers, do: [{"Accept", "application/json"}, {"User-Agent", user_agent()}]

  defp parse_results(%{"query" => %{"search" => results}}) when is_list(results) do
    Enum.flat_map(results, &parse_result/1)
  end

  defp parse_results(_payload), do: []

  defp parse_result(%{"title" => title} = result) do
    [
      %Result{
        title: title,
        url: "https://en.wikipedia.org/wiki/" <> URI.encode(String.replace(title, " ", "_")),
        snippet: result |> Map.get("snippet") |> strip_html(),
        source: "Wikipedia",
        score: Map.get(result, "size", 0),
        metadata: %{provider: :wikipedia, page_id: Map.get(result, "pageid")}
      }
    ]
  end

  defp parse_result(_result), do: []

  defp strip_html(nil), do: nil

  defp strip_html(value) when is_binary(value) do
    value
    |> html_unescape()
    |> String.replace(~r/<[^>]*>/, "")
    |> html_unescape()
  end

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

  defp user_agent, do: Application.get_env(:maid, :user_agent, "Maid/0.1")
end
