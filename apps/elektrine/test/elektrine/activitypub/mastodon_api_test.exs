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

  test "fetch_status_counts ignores object URLs it cannot count directly" do
    assert is_nil(
             MastodonApi.fetch_status_counts(
               "https://akkoma.example/objects/123e4567-e89b-12d3-a456-426614174000"
             )
           )
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
end
