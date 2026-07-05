defmodule Elektrine.ActivityPub.RepliesFetcherTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.RepliesFetcher
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures

  test "returns message_not_found for missing full-thread backfill target" do
    assert {:error, :message_not_found} = RepliesFetcher.fetch_full_thread_for_message(-1)
  end

  test "returns no_activitypub_id when full-thread backfill target is local-only" do
    user = user_fixture()

    message =
      SocialFixtures.post_fixture(%{user: user})
      |> then(fn post ->
        Ecto.Changeset.change(post, activitypub_id: nil, activitypub_url: nil)
      end)
      |> Repo.update!()

    assert {:error, :no_activitypub_id} = RepliesFetcher.fetch_full_thread_for_message(message.id)
  end

  test "imports replies from Mastodon-shaped embedded collections and honors the cooldown" do
    unique = System.unique_integer([:positive])
    actor_uri = "https://remote.example/users/author#{unique}"
    post_id = "#{actor_uri}/statuses/#{unique}"
    reply_id = "#{post_id}/reply-1"
    replies_url = "#{post_id}/replies"
    next_url = "#{replies_url}?only_other_accounts=true&page=true"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: actor_uri,
        username: "author#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/inbox/#{unique}",
        public_key: "test-key-#{unique}"
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "root post",
        visibility: "public",
        activitypub_id: post_id,
        activitypub_url: post_id,
        federated: true,
        remote_actor_id: remote_actor.id
      })

    # The exact shape Mastodon emits: the replies collection embeds its first
    # CollectionPage without an "id", with other-account replies behind "next".
    post_object = %{
      "id" => post_id,
      "type" => "Note",
      "content" => "root post",
      "attributedTo" => actor_uri,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "replies" => %{
        "id" => replies_url,
        "type" => "Collection",
        "first" => %{
          "type" => "CollectionPage",
          "next" => next_url,
          "partOf" => replies_url,
          "items" => []
        }
      }
    }

    reply_object = %{
      "id" => reply_id,
      "type" => "Note",
      "content" => "<p>a reply</p>",
      "attributedTo" => actor_uri,
      "inReplyTo" => post_id,
      "published" => "2026-07-01T00:00:00Z",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    parent = self()

    request_fun = fn url, _headers, _opts ->
      send(parent, {:fetched, url})

      body =
        case url do
          ^post_id ->
            post_object

          ^next_url ->
            %{"type" => "CollectionPage", "partOf" => replies_url, "items" => [reply_object]}
        end

      {:ok,
       %Finch.Response{
         status: 200,
         headers: [{"content-type", "application/activity+json"}],
         body: Jason.encode!(body)
       }}
    end

    assert {:ok, stored} =
             RepliesFetcher.fetch_full_thread_for_message(message.id,
               request_fun: request_fun,
               skip_cache: true,
               validate_url: false
             )

    assert stored >= 1
    assert_received {:fetched, ^post_id}
    assert_received {:fetched, ^next_url}

    reply = Messaging.get_message_by_activitypub_id(reply_id)
    assert reply
    assert reply.reply_to_id == message.id

    # The successful attempt stamped the cooldown: a plain retry short-circuits
    # without hitting the network.
    cooldown_fun = fn url, _headers, _opts ->
      send(parent, {:cooldown_fetch, url})
      {:error, :should_not_be_called}
    end

    assert {:ok, 0} =
             RepliesFetcher.fetch_full_thread_for_message(message.id,
               request_fun: cooldown_fun,
               skip_cache: true,
               validate_url: false
             )

    refute_received {:cooldown_fetch, _}

    # A forced retry (skip_cooldown) bypasses the cooldown and refetches.
    assert {:ok, _} =
             RepliesFetcher.fetch_full_thread_for_message(message.id,
               request_fun: request_fun,
               skip_cache: true,
               skip_cooldown: true,
               validate_url: false
             )

    assert_received {:fetched, ^post_id}
  end
end
