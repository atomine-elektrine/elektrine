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
end
