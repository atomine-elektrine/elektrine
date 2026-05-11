defmodule Elektrine.ActivityPub.CollectionFetcherTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.CollectionFetcher

  describe "fetch_collection/2" do
    test "passes fetch options to collection pages" do
      first_url = "https://remote.example/replies"
      next_url = "https://remote.example/replies?page=2"

      request_fun = fn
        ^first_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "application/activity+json"}],
             body:
               Jason.encode!(%{
                 "type" => "OrderedCollection",
                 "orderedItems" => [%{"id" => "https://remote.example/comments/1"}],
                 "next" => next_url
               })
           }}

        ^next_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "application/activity+json"}],
             body:
               Jason.encode!(%{
                 "type" => "OrderedCollectionPage",
                 "orderedItems" => [%{"id" => "https://remote.example/comments/2"}]
               })
           }}
      end

      assert {:ok, items} =
               CollectionFetcher.fetch_collection(first_url,
                 request_fun: request_fun,
                 skip_cache: true,
                 validate_url: false,
                 max_items: 10,
                 max_pages: 2
               )

      assert Enum.map(items, & &1["id"]) == [
               "https://remote.example/comments/1",
               "https://remote.example/comments/2"
             ]
    end
  end

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
