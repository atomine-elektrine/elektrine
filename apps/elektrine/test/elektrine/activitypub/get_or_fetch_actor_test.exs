defmodule Elektrine.ActivityPub.GetOrFetchActorTest do
  use Elektrine.DataCase, async: true

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
end
