defmodule Elektrine.ActivityPub.MastodonApiTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.MastodonApi

  test "fetch_status_context resolves object URLs through status search" do
    object_url = "https://akkoma.example/objects/123e4567-e89b-12d3-a456-426614174000"

    request_fun = fn :get, url, _headers, _body, _opts ->
      cond do
        String.contains?(url, "/api/v2/search") ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "statuses" => [
                   %{
                     "id" => "root-status",
                     "uri" => object_url,
                     "url" => object_url,
                     "account" => mastodon_account()
                   }
                 ]
               })
           }}

        String.contains?(url, "/api/v1/statuses/root-status/context") ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "ancestors" => [],
                 "descendants" => [
                   %{
                     "id" => "reply-status",
                     "uri" => "https://akkoma.example/objects/reply",
                     "url" => "https://akkoma.example/notice/reply",
                     "content" => "reply",
                     "account" => mastodon_account(),
                     "favourites_count" => 1,
                     "reblogs_count" => 0,
                     "replies_count" => 0,
                     "created_at" => "2026-01-01T00:00:00Z",
                     "in_reply_to_id" => "root-status"
                   }
                 ]
               })
           }}

        true ->
          {:ok, %Finch.Response{status: 404, body: "{}"}}
      end
    end

    assert {:ok, [reply]} = MastodonApi.fetch_status_context(object_url, request_fun: request_fun)
    assert reply.in_reply_to_uri == object_url
    assert reply.account.uri == "https://akkoma.example/users/alice"
  end

  test "fetch_status_counts resolves object URLs through status search" do
    object_url = "https://akkoma.example/objects/123e4567-e89b-12d3-a456-426614174000"

    request_fun = fn :get, url, _headers, _body, _opts ->
      if String.contains?(url, "/api/v2/search") do
        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "statuses" => [
                 %{
                   "id" => "root-status",
                   "uri" => object_url,
                   "favourites_count" => 4,
                   "reblogs_count" => 1,
                   "replies_count" => 2
                 }
               ]
             })
         }}
      else
        {:ok, %Finch.Response{status: 404, body: "{}"}}
      end
    end

    assert %{
             favourites_count: 4,
             reblogs_count: 1,
             replies_count: 2
           } = MastodonApi.fetch_status_counts(object_url, request_fun: request_fun)
  end

  test "fetch_favourited_by resolves object URLs through status search" do
    object_url = "https://akkoma.example/objects/123e4567-e89b-12d3-a456-426614174000"

    request_fun = fn :get, url, _headers, _body, _opts ->
      cond do
        String.contains?(url, "/api/v2/search") ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "statuses" => [%{"id" => "resolved-status", "uri" => object_url}]
               })
           }}

        String.contains?(url, "/api/v1/statuses/resolved-status/favourited_by") ->
          {:ok, %Finch.Response{status: 200, body: Jason.encode!([mastodon_account()])}}

        true ->
          {:ok, %Finch.Response{status: 404, body: "{}"}}
      end
    end

    assert {:ok, [account]} =
             MastodonApi.fetch_favourited_by(object_url, request_fun: request_fun)

    assert account.uri == "https://akkoma.example/users/alice"
  end

  test "fetch_reblogged_by uses activitypub_url fallback for posts" do
    post = %{
      activitypub_id: "https://akkoma.example/objects/123e4567-e89b-12d3-a456-426614174000",
      activitypub_url: "https://akkoma.example/notice/resolved-status"
    }

    request_fun = fn :get, url, _headers, _body, _opts ->
      cond do
        String.contains?(url, "/api/v2/search") ->
          {:ok,
           %Finch.Response{
             status: 200,
             body: Jason.encode!(%{"statuses" => [%{"id" => "resolved-status"}]})
           }}

        String.contains?(url, "/api/v1/statuses/resolved-status/reblogged_by") ->
          {:ok, %Finch.Response{status: 200, body: Jason.encode!([mastodon_account()])}}

        true ->
          {:ok, %Finch.Response{status: 404, body: "{}"}}
      end
    end

    assert {:ok, [account]} =
             MastodonApi.fetch_reblogged_by_for_post(post, request_fun: request_fun)

    assert account.uri == "https://akkoma.example/users/alice"
  end

  test "fetch_status_counts retrieves Misskey note metadata" do
    note_url = "https://misskey.example/notes/abc123"

    request_fun = fn
      :get, _url, _headers, _body, _opts ->
        {:ok, %Finch.Response{status: 404, body: "{}"}}

      :post, url, _headers, body, _opts ->
        assert String.contains?(url, "/api/notes/show")
        assert %{"noteId" => "abc123"} = Jason.decode!(body)

        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "abc123",
               "reactionCount" => 3,
               "renoteCount" => 2,
               "repliesCount" => 1,
               "reactions" => %{"👍" => 2, ":custom@misskey.example:" => 1},
               "files" => [
                 %{
                   "id" => "file1",
                   "type" => "image/png",
                   "url" => "https://misskey.example/files/image.png",
                   "thumbnailUrl" => "https://misskey.example/files/thumb.png",
                   "comment" => "alt"
                 }
               ],
               "renoteId" => "quoted-note",
               "app" => %{"name" => "Misskey Web"}
             })
         }}
    end

    assert %{
             favourites_count: 3,
             reblogs_count: 2,
             replies_count: 1,
             status_metadata: metadata
           } = MastodonApi.fetch_status_counts(note_url, request_fun: request_fun)

    assert [%{"count" => 1}, %{"count" => 2}] =
             Enum.sort_by(metadata["emoji_reactions"], & &1["count"])

    assert [%{"description" => "alt"}] = metadata["media_attachments"]
    assert metadata["quote_id"] == "quoted-note"
    assert metadata["application"] == %{"name" => "Misskey Web"}
  end

  test "fetch_favourited_by retrieves Misskey reactors" do
    note_url = "https://misskey.example/notes/abc123"

    request_fun = fn :post, url, _headers, body, _opts ->
      assert String.contains?(url, "/api/notes/reactions")
      assert %{"noteId" => "abc123", "limit" => 40} = Jason.decode!(body)

      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!([%{"type" => "👍", "user" => misskey_user()}])
       }}
    end

    assert {:ok, [account]} = MastodonApi.fetch_favourited_by(note_url, request_fun: request_fun)
    assert account.acct == "alice@remote.example"
    assert account.display_name == "Alice M"
  end

  test "fetch_reblogged_by retrieves Misskey renoters" do
    note_url = "https://misskey.example/notes/abc123"

    request_fun = fn :post, url, _headers, body, _opts ->
      assert String.contains?(url, "/api/notes/renotes")
      assert %{"noteId" => "abc123", "limit" => 40} = Jason.decode!(body)

      {:ok,
       %Finch.Response{
         status: 200,
         body: Jason.encode!([%{"id" => "renote1", "user" => misskey_user()}])
       }}
    end

    assert {:ok, [account]} = MastodonApi.fetch_reblogged_by(note_url, request_fun: request_fun)
    assert account.uri == "https://remote.example/@alice"
  end

  test "fetch_status_context retrieves Misskey note children" do
    note_url = "https://misskey.example/notes/abc123"

    request_fun = fn :post, url, _headers, body, _opts ->
      assert String.contains?(url, "/api/notes/children")
      assert %{"noteId" => "abc123"} = Jason.decode!(body)

      {:ok,
       %Finch.Response{
         status: 200,
         body:
           Jason.encode!([
             %{
               "id" => "reply1",
               "replyId" => "abc123",
               "text" => "hello",
               "createdAt" => "2026-01-01T00:00:00.000Z",
               "reactionCount" => 1,
               "renoteCount" => 0,
               "repliesCount" => 0,
               "user" => misskey_user()
             }
           ])
       }}
    end

    assert {:ok, [reply]} = MastodonApi.fetch_status_context(note_url, request_fun: request_fun)
    assert reply.id == "reply1"
    assert reply.in_reply_to_uri == note_url
    assert reply.account.acct == "alice@remote.example"
  end

  test "display status URLs are count API compatible" do
    status_url = "https://mastodon.example/@alice/123456789"

    assert MastodonApi.count_api_compatible?(%{activitypub_id: status_url})
    assert MastodonApi.mastodon_compatible?(%{activitypub_id: status_url})
  end

  test "activitypub_url can make an object id count API compatible" do
    post = %{
      activitypub_id: "https://mastodon.example/objects/123e4567-e89b-12d3-a456-426614174000",
      activitypub_url: "https://mastodon.example/@alice/123456789"
    }

    assert MastodonApi.count_api_compatible?(post)
    assert MastodonApi.mastodon_compatible?(post)
  end

  defp mastodon_account do
    %{
      "id" => "alice",
      "username" => "alice",
      "acct" => "alice@akkoma.example",
      "display_name" => "Alice",
      "url" => "https://akkoma.example/@alice",
      "uri" => "https://akkoma.example/users/alice",
      "avatar" => "https://akkoma.example/avatar.png"
    }
  end

  defp misskey_user do
    %{
      "id" => "alice-id",
      "username" => "alice",
      "host" => "remote.example",
      "name" => "Alice M",
      "uri" => "https://remote.example/@alice",
      "avatarUrl" => "https://remote.example/avatar.png"
    }
  end
end
