defmodule MaidTest do
  use ExUnit.Case, async: true

  alias Maid.Result

  defmodule FirstProvider do
    @behaviour Maid.Provider

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
    @behaviour Maid.Provider

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
    @behaviour Maid.Provider

    @impl true
    def search(_query, _opts), do: {:error, :offline}
  end

  defmodule OptsProvider do
    @behaviour Maid.Provider

    @impl true
    def search(_query, opts) do
      send(self(), {:provider_opts, opts})
      {:ok, []}
    end
  end

  defmodule MediaProvider do
    @behaviour Maid.Provider

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
    assert Maid.search("   ") == {:error, :empty_query}
  end

  test "search merges providers, dedupes URLs, and ranks by score" do
    assert {:ok, results} =
             Maid.search("elektrine", providers: [FirstProvider, SecondProvider, BrokenProvider])

    assert [%Result{title: "Better duplicate"}, %Result{title: "Low score result"}] = results
  end

  test "search returns no results without configured providers" do
    assert Maid.search("elektrine", providers: []) == {:ok, []}
  end

  test "search passes runtime options to providers" do
    assert Maid.search("elektrine", providers: [OptsProvider], kind: :images, limit: 12) ==
             {:ok, []}

    assert_received {:provider_opts, opts}
    assert opts[:kind] == :images
    assert opts[:limit] == 12
  end

  test "search keeps meaningful media URL differences while deduping tracking params" do
    assert {:ok, results} = Maid.search("halo", providers: [MediaProvider], limit: 10)

    assert Enum.map(results, & &1.title) == ["Video one", "Video two", "Image one", "Image two"]
  end
end
