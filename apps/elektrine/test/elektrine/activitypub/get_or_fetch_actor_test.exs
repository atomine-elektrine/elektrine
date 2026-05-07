defmodule Elektrine.ActivityPub.GetOrFetchActorTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor

  describe "get_or_fetch_actor/1" do
    test "returns a cached actor for a binary URI" do
      actor = remote_actor_fixture()

      assert {:ok, fetched_actor} = ActivityPub.get_or_fetch_actor(actor.uri)
      assert fetched_actor.id == actor.id
    end

    test "normalizes list-based actor references" do
      actor = remote_actor_fixture()

      assert {:ok, fetched_actor} =
               ActivityPub.get_or_fetch_actor([
                 "",
                 %{"id" => "   "},
                 %{"id" => actor.uri}
               ])

      assert fetched_actor.id == actor.id
    end

    test "normalizes map-based actor references" do
      actor = remote_actor_fixture()

      assert {:ok, fetched_actor} =
               ActivityPub.get_or_fetch_actor(%{
                 "type" => "Person",
                 "id" => actor.uri
               })

      assert fetched_actor.id == actor.id
    end

    test "returns an error for blank input" do
      assert {:error, :invalid_actor_uri} = ActivityPub.get_or_fetch_actor("   ")
    end

    test "returns an error for unsupported actor input shapes" do
      assert {:error, :invalid_actor_uri} = ActivityPub.get_or_fetch_actor(nil)
      assert {:error, :invalid_actor_uri} = ActivityPub.get_or_fetch_actor(%{"type" => "Person"})
    end
  end

  describe "actor profile fields" do
    test "stores long ActivityPub actor URLs without varchar truncation errors" do
      unique = System.unique_integer([:positive])
      long_segment = String.duplicate("a", 280)
      actor_uri = "https://remote.example/users/#{long_segment}-#{unique}"

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: actor_uri,
          username: "longurl#{unique}",
          domain: "remote.example",
          display_name: String.duplicate("Display ", 40),
          avatar_url: "https://remote.example/media/#{long_segment}.png",
          header_url: "https://remote.example/media/#{long_segment}.jpg",
          inbox_url: "#{actor_uri}/inbox/#{long_segment}",
          outbox_url: "#{actor_uri}/outbox/#{long_segment}",
          followers_url: "#{actor_uri}/followers/#{long_segment}",
          following_url: "#{actor_uri}/following/#{long_segment}",
          moderators_url: "#{actor_uri}/moderators/#{long_segment}",
          public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      assert actor.uri == actor_uri
      assert String.length(actor.avatar_url) > 255
      assert String.length(actor.inbox_url) > 255
    end
  end

  describe "get_actor_by_uri/1" do
    test "returns the oldest actor when duplicate uri rows exist" do
      unique = System.unique_integer([:positive])
      uri = "https://remote.example/users/duplicate-#{unique}"

      Repo.query!("DROP INDEX activitypub_actors_uri_index")

      older = insert_actor_with_uri(uri, unique, "older")
      _newer = insert_actor_with_uri(uri, unique, "newer")

      fetched_actor = ActivityPub.get_actor_by_uri(uri)

      assert fetched_actor.id == older.id
      assert fetched_actor.uri == uri
    end
  end

  defp remote_actor_fixture do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/alice-#{unique}",
      username: "alice#{unique}",
      domain: "remote.example",
      inbox_url: "https://remote.example/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp insert_actor_with_uri(uri, unique, suffix) do
    %Actor{}
    |> Actor.changeset(%{
      uri: uri,
      username: "#{suffix}#{unique}",
      domain: "remote.example",
      inbox_url: "https://remote.example/inbox/#{suffix}",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-#{suffix}-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
