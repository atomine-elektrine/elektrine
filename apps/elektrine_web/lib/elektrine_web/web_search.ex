defmodule ElektrineWeb.WebSearch do
  @moduledoc """
  Cached front-end for Paige web search.

  Results are cached per query/kind/limit so repeat searches don't hit the
  paid provider APIs again. Degraded responses (where one or more providers
  failed or timed out) are returned but not cached, so a provider hiccup
  doesn't pin incomplete results for the whole TTL.
  """

  alias Elektrine.AppCache

  @spec search(String.t(), keyword()) ::
          {:ok, [Paige.Result.t()], map()} | {:error, term()}
  def search(query, opts \\ []) do
    kind = Keyword.get(opts, :kind, :web)
    limit = Keyword.get(opts, :limit, 10)

    if cache_enabled?() do
      AppCache.get_web_search_results({kind, limit, query}, fn ->
        case Paige.search_detailed(query, kind: kind, limit: limit) do
          {:ok, _results, %{degraded?: false}} = success -> {:commit, success}
          other -> {:ignore, other}
        end
      end)
    else
      Paige.search_detailed(query, kind: kind, limit: limit)
    end
  end

  defp cache_enabled? do
    Application.get_env(:elektrine_web, :web_search_cache_enabled, true)
  end
end
