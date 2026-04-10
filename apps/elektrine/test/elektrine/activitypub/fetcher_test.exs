defmodule Elektrine.ActivityPub.FetcherTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Fetcher

  describe "fetch_object/2" do
    test "rejects unsafe URLs before making a request" do
      assert {:error, :unsafe_url} =
               Fetcher.fetch_object("http://127.0.0.1/notes/1", skip_cache: true)
    end

    test "recovers Lemmy posts when the post URL returns HTML" do
      post_uri = "https://startrek.website/post/37631588"

      resolve_url =
        "https://startrek.website/api/v4/resolve_object?q=https%3A%2F%2Fstartrek.website%2Fpost%2F37631588"

      request_fun = fn
        ^post_uri, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: "<!DOCTYPE html><html><body>post page</body></html>"
           }}

        ^resolve_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "post" => %{
                   "post" => %{
                     "ap_id" => post_uri,
                     "name" => "A Star Trek post",
                     "body" => "Body content",
                     "published" => "2026-01-30T02:18:24.601576Z",
                     "url" => "https://example.com/star-trek-post"
                   },
                   "creator" => %{
                     "actor_id" => "https://startrek.website/u/TribblesBestFriend",
                     "name" => "TribblesBestFriend"
                   },
                   "community" => %{
                     "actor_id" => "https://startrek.website/c/startrek"
                   },
                   "counts" => %{"comments" => 96, "score" => 12}
                 }
               })
           }}
      end

      assert {:ok, object} =
               Fetcher.fetch_object(post_uri, skip_cache: true, request_fun: request_fun)

      assert object["id"] == post_uri
      assert object["type"] == "Page"
      assert object["content"] == "Body content"
      assert object["attributedTo"] == "https://startrek.website/u/TribblesBestFriend"
      assert get_in(object, ["comments", "totalItems"]) == 96

      assert object["attachment"] == [
               %{
                 "type" => "Link",
                 "href" => "https://example.com/star-trek-post",
                 "name" => "A Star Trek post"
               }
             ]
    end
  end

  describe "webfinger_lookup/2" do
    test "rejects private domains before making a request" do
      assert {:error, :unsafe_url} =
               Fetcher.webfinger_lookup("alice@127.0.0.1", skip_cache: true)
    end
  end

  describe "fetch_and_cache_actor/2" do
    test "rejects actor documents whose id does not match the requested URI" do
      actor_uri = "http://8.8.8.8/users/alice"

      request_fun = fn ^actor_uri, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "http://1.1.1.1/users/bob",
               "type" => "Person",
               "preferredUsername" => "bob",
               "inbox" => "http://1.1.1.1/inbox",
               "outbox" => "http://1.1.1.1/outbox",
               "followers" => "http://1.1.1.1/users/bob/followers",
               "following" => "http://1.1.1.1/users/bob/following"
             })
         }}
      end

      assert {:error, :actor_id_mismatch} =
               ActivityPub.fetch_and_cache_actor(actor_uri, request_fun: request_fun)
    end

    test "rejects actor documents that advertise unsafe inboxes" do
      actor_uri = "http://8.8.8.8/users/alice"

      request_fun = fn ^actor_uri, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => actor_uri,
               "type" => "Person",
               "preferredUsername" => "alice",
               "inbox" => "http://127.0.0.1/inbox",
               "outbox" => "http://8.8.8.8/outbox",
               "followers" => "http://8.8.8.8/users/alice/followers",
               "following" => "http://8.8.8.8/users/alice/following"
             })
         }}
      end

      assert {:error, :unsafe_actor_document} =
               ActivityPub.fetch_and_cache_actor(actor_uri, request_fun: request_fun)
    end

    test "recovers Lemmy actors when the actor URL returns HTML" do
      actor_uri = "https://startrek.website/u/TribblesBestFriend"

      resolve_url =
        "https://startrek.website/api/v4/resolve_object?q=https%3A%2F%2Fstartrek.website%2Fu%2FTribblesBestFriend"

      request_fun = fn
        ^actor_uri, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: "<!DOCTYPE html><html><body>profile page</body></html>"
           }}

        ^resolve_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "person" => %{
                   "person" => %{
                     "name" => "TribblesBestFriend",
                     "actor_id" => actor_uri,
                     "published" => "2025-01-30T02:18:24.601576Z"
                   }
                 }
               })
           }}
      end

      assert {:ok, actor} = ActivityPub.fetch_and_cache_actor(actor_uri, request_fun: request_fun)
      assert actor.uri == actor_uri
      assert actor.username == "TribblesBestFriend"
      assert actor.inbox_url == "https://startrek.website/u/TribblesBestFriend/inbox"
    end
  end
end
