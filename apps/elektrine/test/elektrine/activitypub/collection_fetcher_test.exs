defmodule Elektrine.ActivityPub.CollectionFetcherTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.CollectionFetcher

  describe "fetch_collection_count/1" do
    test "falls back to counting ordered items when totalItems is malformed" do
      collection = %{
        "type" => "OrderedCollection",
        "totalItems" => "unknown",
        "orderedItems" => [
          %{"id" => "https://remote.example/posts/1"},
          %{"id" => "https://remote.example/posts/2"}
        ]
      }

      assert {:ok, 2} = CollectionFetcher.fetch_collection_count(collection)
    end

    test "returns zero when totalItems is malformed and no items are present" do
      collection = %{
        "type" => "OrderedCollection",
        "totalItems" => "n/a"
      }

      assert {:ok, 0} = CollectionFetcher.fetch_collection_count(collection)
    end
  end
end
