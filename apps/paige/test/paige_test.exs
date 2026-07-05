defmodule MaidTest do
  use ExUnit.Case, async: true

  alias Paige.Result

  defmodule FirstProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %Result{
           title: "Elektrine search",
           url: "https://example.com/search?utm_source=test",
           snippet: "First result",
           score: 10
         },
         %{
           title: "Low score result",
           url: "https://example.com/low",
           snippet: "Still valid",
           score: 1
         }
       ]}
    end
  end

  defmodule SecondProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %Result{
           title: "Better duplicate",
           url: "https://example.com/search#section",
           snippet: "Same canonical URL, higher score",
           score: 20
         }
       ]}
    end
  end

  defmodule BrokenProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts), do: {:error, :offline}
  end

  defmodule OptsProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, opts) do
      # Providers run inside tasks, so notify the test process explicitly.
      if pid = Keyword.get(opts, :notify), do: send(pid, {:provider_opts, opts})
      {:ok, []}
    end
  end

  defmodule SlowProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 300))

      {:ok,
       [
         %Result{
           title: "Slow result",
           url: "https://slow.example/",
           snippet: "Took a while",
           score: 5
         }
       ]}
    end
  end

  defmodule MediaProvider do
    @behaviour Paige.Provider

    @impl true
    def search(_query, _opts) do
      {:ok,
       [
         %Result{
           title: "Video one",
           url: "https://www.youtube.com/watch?v=one",
           score: 10,
           metadata: %{kind: :videos}
         },
         %Result{
           title: "Video two",
           url: "https://www.youtube.com/watch?v=two",
           score: 9,
           metadata: %{kind: :videos}
         },
         %Result{
           title: "Image one",
           url: "https://example.com/gallery",
           score: 8,
           metadata: %{kind: :images, image_url: "https://cdn.example.com/one.jpg"}
         },
         %Result{
           title: "Image two",
           url: "https://example.com/gallery",
           score: 7,
           metadata: %{kind: :images, image_url: "https://cdn.example.com/two.jpg"}
         }
       ]}
    end
  end

  test "rejects empty queries" do
    assert Paige.search("   ") == {:error, :empty_query}
  end

  test "search merges providers, dedupes URLs, and ranks by score" do
    assert {:ok, results} =
             Paige.search("elektrine", providers: [FirstProvider, SecondProvider, BrokenProvider])

    assert [%Result{title: "Better duplicate"}, %Result{title: "Low score result"}] = results
  end

  test "search returns no results without configured providers" do
    assert Paige.search("elektrine", providers: []) == {:ok, []}
  end

  test "search passes runtime options to providers" do
    assert Paige.search("elektrine",
             providers: [OptsProvider],
             kind: :images,
             limit: 12,
             notify: self()
           ) ==
             {:ok, []}

    assert_received {:provider_opts, opts}
    assert opts[:kind] == :images
    assert opts[:limit] == 12
  end

  test "search runs providers concurrently" do
    {elapsed_us, {:ok, results}} =
      :timer.tc(fn ->
        Paige.search("elektrine",
          providers: [SlowProvider, {SlowProvider, []}, FirstProvider],
          sleep_ms: 300
        )
      end)

    assert Enum.any?(results, &(&1.title == "Slow result"))
    # Two 300ms providers run in parallel, so total time stays well under 600ms.
    assert elapsed_us < 550_000
  end

  test "search treats providers that exceed the timeout as failed" do
    assert {:ok, results, meta} =
             Paige.search_detailed("elektrine",
               providers: [SlowProvider, FirstProvider],
               sleep_ms: 500,
               provider_timeout: 100
             )

    assert Enum.map(results, & &1.title) == ["Elektrine search", "Low score result"]
    assert meta.degraded?
    assert [{SlowProvider, :timeout}] = meta.failed_providers
  end

  test "search skips providers that do not handle the requested kind" do
    assert {:ok, []} =
             Paige.search("elektrine",
               providers: [{OptsProvider, [kinds: [:web]]}],
               kind: :images,
               notify: self()
             )

    refute_received {:provider_opts, _opts}

    assert {:ok, []} =
             Paige.search("elektrine",
               providers: [{OptsProvider, [kinds: [:web]]}],
               kind: :web,
               notify: self()
             )

    assert_received {:provider_opts, _opts}
  end

  test "search_detailed reports partial provider failures" do
    assert {:ok, results, meta} =
             Paige.search_detailed("elektrine", providers: [FirstProvider, BrokenProvider])

    assert results != []
    assert meta.degraded?
    assert [{BrokenProvider, :offline}] = meta.failed_providers
  end

  test "search_detailed reports healthy searches as not degraded" do
    assert {:ok, _results, %{degraded?: false, failed_providers: []}} =
             Paige.search_detailed("elektrine", providers: [FirstProvider])
  end

  test "search_detailed errors when every provider fails" do
    assert Paige.search_detailed("elektrine", providers: [BrokenProvider]) ==
             {:error, :providers_unavailable}
  end

  test "provider ranking options rescore, offset, and cap results" do
    assert {:ok, results} =
             Paige.search("elektrine",
               providers: [{FirstProvider, [scoring: :rank, score_offset: -5, max_results: 1]}]
             )

    # The top result is rescored from its native 10 to 1000 - 0 - 5 = 995 and
    # the provider's second result is dropped by max_results.
    assert [%Result{title: "Elektrine search", score: 995}] = results
  end

  test "search keeps meaningful media URL differences while deduping tracking params" do
    assert {:ok, results} = Paige.search("halo", providers: [MediaProvider], limit: 10)

    assert Enum.map(results, & &1.title) == ["Video one", "Video two", "Image one", "Image two"]
  end
end
