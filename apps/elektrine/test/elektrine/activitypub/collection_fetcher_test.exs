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

    test "traverses Mastodon-style embedded first pages that have no id" do
      replies_url = "https://remote.example/statuses/1/replies"
      next_url = "#{replies_url}?only_other_accounts=true&page=true"

      collection = %{
        "id" => replies_url,
        "type" => "Collection",
        "first" => %{
          "type" => "CollectionPage",
          "next" => next_url,
          "partOf" => replies_url,
          "items" => [%{"id" => "https://remote.example/statuses/2"}]
        }
      }

      request_fun = fn ^next_url, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [{"content-type", "application/activity+json"}],
           body:
             Jason.encode!(%{
               "type" => "CollectionPage",
               "partOf" => replies_url,
               "items" => [%{"id" => "https://remote.example/statuses/3"}]
             })
         }}
      end

      assert {:ok, items} =
               CollectionFetcher.fetch_collection(collection,
                 request_fun: request_fun,
                 skip_cache: true,
                 validate_url: false,
                 max_items: 10,
                 max_pages: 3
               )

      assert Enum.map(items, & &1["id"]) == [
               "https://remote.example/statuses/2",
               "https://remote.example/statuses/3"
             ]
    end

    test "fetches bare embedded first page references by id" do
      first_url = "https://remote.example/collection?page=1"

      collection = %{
        "type" => "Collection",
        "first" => %{"id" => first_url}
      }

      request_fun = fn ^first_url, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [{"content-type", "application/activity+json"}],
           body:
             Jason.encode!(%{
               "type" => "CollectionPage",
               "items" => [%{"id" => "https://remote.example/comments/9"}]
             })
         }}
      end

      assert {:ok, items} =
               CollectionFetcher.fetch_collection(collection,
                 request_fun: request_fun,
                 skip_cache: true,
                 validate_url: false,
                 max_items: 10,
                 max_pages: 2
               )

      assert Enum.map(items, & &1["id"]) == ["https://remote.example/comments/9"]
    end

    test "follows the id of untyped count-only collection references" do
      collection_url = "https://remote.example/statuses/1/comments"

      request_fun = fn ^collection_url, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [{"content-type", "application/activity+json"}],
           body:
             Jason.encode!(%{
               "type" => "OrderedCollection",
               "totalItems" => 2,
               "orderedItems" => [
                 %{"id" => "https://remote.example/comments/1"},
                 %{"id" => "https://remote.example/comments/2"}
               ]
             })
         }}
      end

      assert {:ok, items} =
               CollectionFetcher.fetch_collection(
                 %{"id" => collection_url, "totalItems" => 74},
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

    test "follows the id of typed count-only collection references" do
      collection_url = "https://remote.example/statuses/1/replies"

      request_fun = fn ^collection_url, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [{"content-type", "application/activity+json"}],
           body:
             Jason.encode!(%{
               "type" => "OrderedCollection",
               "orderedItems" => [%{"id" => "https://remote.example/comments/typed"}]
             })
         }}
      end

      assert {:ok, items} =
               CollectionFetcher.fetch_collection(
                 %{"id" => collection_url, "type" => "Collection", "totalItems" => 1},
                 request_fun: request_fun,
                 skip_cache: true,
                 validate_url: false,
                 max_items: 10,
                 max_pages: 2
               )

      assert Enum.map(items, & &1["id"]) == ["https://remote.example/comments/typed"]
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
