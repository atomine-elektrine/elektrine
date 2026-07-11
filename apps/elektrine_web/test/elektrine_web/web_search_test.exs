defmodule ElektrineWeb.WebSearchTest do
  # async: false — toggles global :paige provider config and the shared cache flag.
  use ExUnit.Case, async: false

  alias ElektrineWeb.WebSearch

  defmodule NotifyingProvider do
    @behaviour Paige.Provider

    @impl true
    def search(query, opts) do
      notify = Keyword.fetch!(opts, :notify)
      send(notify, :provider_called)
      send(notify, {:provider_request, query, opts})

      if delay_ms = Keyword.get(opts, :delay_ms) do
        Process.sleep(delay_ms)
      end

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

  test "does not cache an unavailable unconfigured vertical" do
    query = unique_query()
    Application.put_env(:paige, :providers, [])

    assert {:ok, [], %{available?: false}} =
             WebSearch.search(query, kind: :images, limit: 5)

    Application.put_env(:paige, :providers, [{NotifyingProvider, [notify: self()]}])

    assert {:ok, [_result], %{available?: true}} =
             WebSearch.search(query, kind: :images, limit: 5)

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

  test "normalizes the query before forwarding it and building the cache key" do
    Application.put_env(:paige, :providers, [{NotifyingProvider, [notify: self()]}])
    query = "query-normalization-#{System.unique_integer([:positive])}"

    assert {:ok, _results, _meta} =
             WebSearch.search("  #{query}\n\twith    spacing  ", kind: :web, limit: 5)

    assert_receive {:provider_request, forwarded_query, _opts}
    assert forwarded_query == "#{query} with spacing"
    assert_received :provider_called

    assert {:ok, _results, _meta} =
             WebSearch.search("#{query} with spacing", kind: :web, limit: 5)

    refute_received :provider_called

    assert {:ok, cache_keys} = Cachex.keys(:app_cache)
    refute Enum.any?(cache_keys, &String.contains?(inspect(&1), query))
  end

  test "isolates cache entries by every result-affecting option and forwards normalized opts" do
    Application.put_env(:paige, :providers, [{NotifyingProvider, [notify: self()]}])
    query = unique_query()

    variants = [
      [kind: :web, limit: 5],
      [kind: :web, limit: 5, page: 2],
      [kind: :web, limit: 5, freshness: "week"],
      [kind: :web, limit: 5, safesearch: "strict"],
      [kind: :web, limit: 5, country: "ca"],
      [kind: :web, limit: 5, search_lang: "fr"],
      [kind: :web, limit: 5, spellcheck: false]
    ]

    Enum.each(variants, fn opts ->
      assert {:ok, _results, _meta} = WebSearch.search(query, opts)
      assert_receive :provider_called
      assert_receive {:provider_request, ^query, provider_opts}

      actual_opts =
        provider_opts
        |> Keyword.take([
          :kind,
          :limit,
          :page,
          :freshness,
          :safesearch,
          :country,
          :search_lang,
          :spellcheck
        ])
        |> Map.new()

      expected_opts = opts |> normalized_expected_opts() |> Map.new()
      assert actual_opts == expected_opts
    end)

    equivalent_opts = [
      kind: "WEB",
      limit: 5,
      page: "2",
      freshness: :all,
      safesearch: "MODERATE",
      country: " US ",
      search_lang: "EN",
      spellcheck: "true"
    ]

    assert {:ok, _results, _meta} = WebSearch.search(query, equivalent_opts)
    refute_received :provider_called
  end

  test "coalesces concurrent identical cache misses" do
    Application.put_env(:paige, :providers, [
      {NotifyingProvider, [notify: self(), delay_ms: 100]}
    ])

    query = unique_query()
    parent = self()

    tasks =
      for _index <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> WebSearch.search(query, kind: :web, limit: 5)
          end
        end)
      end

    task_pids =
      for _index <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(task_pids, &send(&1, :go))

    Enum.each(tasks, fn task ->
      assert {:ok, _results, _meta} = Task.await(task, 2_000)
    end)

    assert_receive :provider_called
    refute_receive :provider_called, 200
  end

  defp normalized_expected_opts(opts) do
    [
      kind: :web,
      limit: 5,
      page: Keyword.get(opts, :page, 1),
      freshness:
        case Keyword.get(opts, :freshness) do
          "week" -> "pw"
          _value -> nil
        end,
      safesearch: Keyword.get(opts, :safesearch, "moderate"),
      country: Keyword.get(opts, :country, "us"),
      search_lang: Keyword.get(opts, :search_lang, "en"),
      spellcheck: if(Keyword.get(opts, :spellcheck, true), do: 1, else: 0)
    ]
  end
end
