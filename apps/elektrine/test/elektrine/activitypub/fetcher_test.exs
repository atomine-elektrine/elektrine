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

    test "does not recover Lemmy posts when recovery is disabled" do
      post_uri = "https://startrek.website/post/37631588"

      request_fun = fn ^post_uri, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [{"content-type", "text/html; charset=utf-8"}],
           body: "<!DOCTYPE html><html><body>post page</body></html>"
         }}
      end

      assert {:error, :invalid_json} =
               Fetcher.fetch_object(post_uri,
                 skip_cache: true,
                 allow_recovery: false,
                 request_fun: request_fun
               )
    end

    test "recovers Lemmy comments when the comment URL returns HTML" do
      comment_uri = "https://startrek.website/comment/22443688"

      resolve_url =
        "https://startrek.website/api/v4/resolve_object?q=https%3A%2F%2Fstartrek.website%2Fcomment%2F22443688"

      request_fun = fn
        ^comment_uri, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: "<!DOCTYPE html><html><body>comment page</body></html>"
           }}

        ^resolve_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "comment" => %{
                   "comment" => %{
                     "ap_id" => comment_uri,
                     "content" => "Comment body",
                     "published" => "2026-04-16T00:00:00Z",
                     "path" => "0.22440000.22443688"
                   },
                   "creator" => %{
                     "actor_id" => "https://startrek.website/u/threecoloured",
                     "name" => "threecoloured"
                   },
                   "post" => %{
                     "ap_id" => "https://startrek.website/post/37631588"
                   },
                   "community" => %{
                     "actor_id" => "https://startrek.website/c/startrek"
                   },
                   "counts" => %{"child_count" => 7, "score" => 9, "upvotes" => 11}
                 }
               })
           }}
      end

      assert {:ok, object} =
               Fetcher.fetch_object(comment_uri, skip_cache: true, request_fun: request_fun)

      assert object["id"] == comment_uri
      assert object["type"] == "Note"
      assert object["content"] == "Comment body"
      assert object["attributedTo"] == "https://startrek.website/u/threecoloured"
      assert object["inReplyTo"] == "https://startrek.website/comment/22440000"
      assert get_in(object, ["replies", "totalItems"]) == 7
      assert get_in(object, ["_lemmy", "upvotes"]) == 11
    end

    test "recovers Lemmy comments from routeData html with undefined values" do
      comment_uri = "https://adultswim.fan/comment/8755826"

      request_fun = fn
        ^comment_uri, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: """
             <!DOCTYPE html>
             <html>
             <head>
             <script>
             window.isoData = {"path":"/comment/8755826","routeData":{"postRes":{"data":{"post_view":{"post":{"ap_id":"https://lemmy.world/post/45711923","url":"https://example.com/story","name":"Example story"},"creator":{"actor_id":"https://lemmy.world/u/return2ozma","name":"return2ozma"},"community":{"actor_id":"https://lemmy.world/c/technology"},"counts":{"comments":21}}},"state":"success"},"commentsRes":{"data":{"comments":[{"comment":{"id":8755826,"content":"How does one 'learn AI'?","published":"2026-04-17T15:22:18.397007Z","ap_id":"https://lemmy.world/comment/23270371","path":"0.8755826"},"creator":{"actor_id":"https://lemmy.world/u/StaticFalconar","name":"StaticFalconar"},"post":{"ap_id":"https://lemmy.world/post/45711923"},"community":{"actor_id":"https://lemmy.world/c/technology"},"counts":{"comment_id":8755826,"score":47,"upvotes":48,"downvotes":1,"child_count":21}}]},"state":"success"}},"errorPageData":undefined};
             </script>
             </head>
             <body></body>
             </html>
             """
           }}
      end

      assert {:ok, object} =
               Fetcher.fetch_object(comment_uri, skip_cache: true, request_fun: request_fun)

      assert object["id"] == "https://lemmy.world/comment/23270371"
      assert object["type"] == "Note"
      assert object["content"] == "How does one 'learn AI'?"
      assert object["attributedTo"] == "https://lemmy.world/u/StaticFalconar"
      assert object["inReplyTo"] == "https://lemmy.world/post/45711923"
      assert get_in(object, ["replies", "totalItems"]) == 21
      assert get_in(object, ["_lemmy", "upvotes"]) == 48
    end

    test "recovers Mastodon status objects when the AP URL returns 404" do
      status_uri = "https://mastodon.world/users/alice/statuses/115379251737165990"
      api_url = "https://mastodon.world/api/v1/statuses/115379251737165990"

      request_fun = fn
        ^status_uri, _headers, _opts ->
          {:ok, %Finch.Response{status: 404, headers: [], body: ""}}

        ^api_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "application/json"}],
             body:
               Jason.encode!(%{
                 "uri" => status_uri,
                 "url" => "https://mastodon.world/@alice/115379251737165990",
                 "content" => "<p>Hello from API fallback</p>",
                 "created_at" => "2026-04-16T00:00:00Z",
                 "visibility" => "public",
                 "sensitive" => false,
                 "spoiler_text" => "",
                 "media_attachments" => [],
                 "account" => %{"username" => "alice"}
               })
           }}
      end

      assert {:ok, object} =
               Fetcher.fetch_object(status_uri, skip_cache: true, request_fun: request_fun)

      assert object["id"] == status_uri
      assert object["type"] == "Note"
      assert object["attributedTo"] == "https://mastodon.world/users/alice"
      assert object["url"] == "https://mastodon.world/@alice/115379251737165990"
      assert object["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
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

    test "accepts actor documents that use /ap/users canonical ids on the same host" do
      actor_uri = "https://mastodon.social/users/Sea1Am"

      request_fun = fn ^actor_uri, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "https://mastodon.social/ap/users/116313284892040418",
               "type" => "Person",
               "preferredUsername" => "Sea1Am",
               "inbox" => "https://mastodon.social/users/Sea1Am/inbox",
               "outbox" => "https://mastodon.social/users/Sea1Am/outbox",
               "followers" => "https://mastodon.social/users/Sea1Am/followers",
               "following" => "https://mastodon.social/users/Sea1Am/following",
               "publicKey" => %{
                 "id" => "https://mastodon.social/ap/users/116313284892040418#main-key",
                 "owner" => "https://mastodon.social/ap/users/116313284892040418",
                 "publicKeyPem" => "-----BEGIN PUBLIC KEY-----\nSEA1AM\n-----END PUBLIC KEY-----"
               }
             })
         }}
      end

      assert {:ok, actor} = ActivityPub.fetch_and_cache_actor(actor_uri, request_fun: request_fun)
      assert actor.uri == "https://mastodon.social/ap/users/116313284892040418"
      assert actor.username == "Sea1Am"
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

    test "does not recover Lemmy actors when recovery is disabled" do
      actor_uri = "https://startrek.website/u/TribblesBestFriend"

      request_fun = fn ^actor_uri, _headers, _opts ->
        {:ok,
         %Finch.Response{
           status: 200,
           headers: [{"content-type", "text/html; charset=utf-8"}],
           body: "<!DOCTYPE html><html><body>profile page</body></html>"
         }}
      end

      assert {:error, :invalid_json} =
               ActivityPub.fetch_and_cache_actor(actor_uri,
                 request_fun: request_fun,
                 allow_recovery: false
               )
    end

    test "recovers Lemmy site actors when the actor URL is the instance root" do
      actor_uri = "https://startrek.website/"
      site_url = "https://startrek.website/api/v4/site"

      request_fun = fn
        ^actor_uri, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             headers: [{"content-type", "text/html; charset=utf-8"}],
             body: "<!DOCTYPE html><html><body>home page</body></html>"
           }}

        ^site_url, _headers, _opts ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "site_view" => %{
                   "site" => %{
                     "actor_id" => actor_uri,
                     "name" => "Star Trek Website",
                     "description" => "A Lemmy instance",
                     "published" => "2023-06-11T18:36:08.306144Z",
                     "icon" => "https://startrek.website/icon.png",
                     "banner" => "https://startrek.website/banner.png",
                     "inbox_url" => "https://startrek.website/inbox",
                     "public_key" =>
                       "-----BEGIN PUBLIC KEY-----\nSITEKEY\n-----END PUBLIC KEY-----"
                   }
                 }
               })
           }}
      end

      assert {:ok, actor} = ActivityPub.fetch_and_cache_actor(actor_uri, request_fun: request_fun)
      assert actor.uri == actor_uri
      assert actor.username == "startrek.website"
      assert actor.actor_type == "Application"
      assert actor.inbox_url == "https://startrek.website/inbox"
      assert actor.public_key == "-----BEGIN PUBLIC KEY-----\nSITEKEY\n-----END PUBLIC KEY-----"
    end

    test "does not retry signed fetch when Cloudflare blocks the actor URL" do
      actor_uri = "https://example.com/u/blocked"
      host = "example.com"
      calls = :counters.new(1, [])

      Elektrine.HTTP.Backoff.clear_backoff(host)

      request_fun = fn ^actor_uri, _headers, _opts ->
        :counters.add(calls, 1, 1)

        {:ok,
         %Finch.Response{
           status: 403,
           headers: [
             {"content-type", "text/html; charset=UTF-8"},
             {"server", "cloudflare"}
           ],
           body:
             "<!DOCTYPE html><html><head><title>Attention Required! | Cloudflare</title></head><body>Sorry, you have been blocked. Cloudflare Ray ID: 123</body></html>"
         }}
      end

      assert {:error, :fetch_failed} =
               ActivityPub.fetch_and_cache_actor(actor_uri, request_fun: request_fun)

      assert :counters.get(calls, 1) == 1
      assert Elektrine.HTTP.Backoff.should_backoff?(host)

      Elektrine.HTTP.Backoff.clear_backoff(host)
    end
  end
end
