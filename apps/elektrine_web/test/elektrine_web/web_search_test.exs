defmodule ElektrineWeb.WebSearchTest do
  # async: false — toggles global :paige provider config and the shared cache flag.
  use ExUnit.Case, async: false

  alias ElektrineWeb.WebSearch

  defmodule NotifyingProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, opts) do
      send(Keyword.fetch!(opts, :notify), :provider_called)

      {:ok,
       [
         %{
           title: "Cached result",
           url: "https://cache.example/",
           snippet: "hello",
           score: 10
         }
       ]}
    end
  end

  defmodule FailingProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts), do: {:error, :offline}
  end

  setup do
    previous_providers = Application.get_env(:paige, :providers, [])
    previous_cache = Application.get_env(:elektrine_web, :web_search_cache_enabled)

    Application.put_env(:elektrine_web, :web_search_cache_enabled, true)

    on_exit(fn ->
      Application.put_env(:paige, :providers, previous_providers)
      Application.put_env(:elektrine_web, :web_search_cache_enabled, previous_cache)
    end)

    :ok
  end

  defp unique_query, do: "web-search-cache-#{System.unique_integer([:positive])}"

  test "serves repeat searches from the cache" do
    Application.put_env(:paige, :providers, [{NotifyingProvider, [notify: self()]}])
    query = unique_query()

    assert {:ok, [result], %{degraded?: false}} = WebSearch.search(query, kind: :web, limit: 5)
    assert result.title == "Cached result"
    assert_received :provider_called

    assert {:ok, [_result], %{degraded?: false}} = WebSearch.search(query, kind: :web, limit: 5)
    refute_received :provider_called
  end

  test "does not cache degraded results" do
    Application.put_env(:paige, :providers, [
      {NotifyingProvider, [notify: self()]},
      FailingProvider
    ])

    query = unique_query()

    assert {:ok, [_result], %{degraded?: true}} = WebSearch.search(query, kind: :web, limit: 5)
    assert_received :provider_called

    assert {:ok, [_result], %{degraded?: true}} = WebSearch.search(query, kind: :web, limit: 5)
    assert_received :provider_called
  end

  test "caches per kind and limit" do
    Application.put_env(:paige, :providers, [{NotifyingProvider, [notify: self()]}])
    query = unique_query()

    assert {:ok, _results, _meta} = WebSearch.search(query, kind: :web, limit: 5)
    assert_received :provider_called

    assert {:ok, _results, _meta} = WebSearch.search(query, kind: :web, limit: 10)
    assert_received :provider_called
  end
end
