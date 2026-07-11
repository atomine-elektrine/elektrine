defmodule Paige.Providers.GitHub do
  @moduledoc "GitHub repository search provider for Paige."

  @behaviour Paige.Provider

  alias Paige.Result

  @endpoint "https://api.github.com/search/repositories"

  @impl true
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    case Paige.HTTP.get_json(url(query, opts), headers(opts), opts) do
      {:ok, payload} -> parse_results(payload)
      {:error, reason} -> {:error, reason}
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  defp url(query, opts) do
    limit = opts |> Keyword.get(:limit, 10) |> clamp_limit(30)
    page = normalize_page(Keyword.get(opts, :page, 1))

    query_string =
      URI.encode_query(%{
        q: query,
        page: page,
        per_page: limit,
        sort: "stars",
        order: "desc"
      })

    @endpoint <> "?" <> query_string
  end

  defp headers(opts) do
    token = Keyword.get(opts, :token) || Application.get_env(:paige, :github_token)

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
    {:ok, Enum.flat_map(items, &parse_item/1)}
  end

  defp parse_results(_payload), do: {:error, :invalid_response}

  defp parse_item(%{"full_name" => full_name, "html_url" => url} = item)
       when is_binary(full_name) and is_binary(url) do
    stars = numeric_value(Map.get(item, "stargazers_count"))

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

  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_value), do: 0

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

  defp user_agent, do: Application.get_env(:paige, :user_agent, "Paige/0.1")
end
