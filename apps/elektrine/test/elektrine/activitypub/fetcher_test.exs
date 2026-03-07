defmodule Elektrine.ActivityPub.FetcherTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Fetcher

  describe "fetch_object/2" do
    test "rejects unsafe URLs before making a request" do
      assert {:error, :unsafe_url} =
               Fetcher.fetch_object("http://127.0.0.1/notes/1", skip_cache: true)
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
  end
end
