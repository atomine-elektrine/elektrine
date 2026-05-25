defmodule Maid.Providers.GitHub do
  @moduledoc "GitHub repository search provider for Maid."

  @behaviour Maid.Provider

  alias Maid.Result

  @endpoint "https://api.github.com/search/repositories"

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    case Maid.HTTP.get_json(url(query, opts), headers(opts), opts) do
      {:ok, payload} -> {:ok, parse_results(payload)}
      {:error, reason} -> {:error, reason}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp url(query, opts) do
    limit = opts |> Keyword.get(:limit, 10) |> clamp_limit(30)

    query_string =
      URI.encode_query(%{
        q: query,
        per_page: limit,
        sort: "stars",
        order: "desc"
      })

    @endpoint <> "?" <> query_string
  end

  defp headers(opts) do
    token = Keyword.get(opts, :token) || Application.get_env(:maid, :github_token)

    [
      {"Accept", "application/vnd.github+json"},
      {"User-Agent", user_agent()}
    ]
    |> maybe_put_auth(token)
  end

  defp maybe_put_auth(headers, token) when is_binary(token) do
    if String.trim(token) == "",
      do: headers,
      else: [{"Authorization", "Bearer #{token}"} | headers]
  end

  defp maybe_put_auth(headers, _token), do: headers

  defp parse_results(%{"items" => items}) when is_list(items) do
    Enum.flat_map(items, &parse_item/1)
  end

  defp parse_results(_payload), do: []

  defp parse_item(%{"full_name" => full_name, "html_url" => url} = item) do
    stars = Map.get(item, "stargazers_count") || 0

    [
      %Result{
        title: full_name,
        url: url,
        snippet: Map.get(item, "description"),
        source: "GitHub",
        score: stars,
        published_at: parse_datetime(Map.get(item, "pushed_at")),
        metadata: %{
          provider: :github,
          stars: stars,
          language: Map.get(item, "language")
        }
      }
    ]
  end

  defp parse_item(_item), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp clamp_limit(limit, max) when is_integer(limit), do: limit |> max(1) |> min(max)
  defp clamp_limit(_limit, _max), do: 10

  defp user_agent, do: Application.get_env(:maid, :user_agent, "Maid/0.1")
end
