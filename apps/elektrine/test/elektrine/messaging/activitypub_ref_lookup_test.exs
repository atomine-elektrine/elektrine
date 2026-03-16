defmodule Elektrine.Messaging.ActivityPubRefLookupTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message

  describe "get_message_by_activitypub_ref/1" do
    test "matches refs with query and fragment variants" do
      actor = remote_actor_fixture()
      activitypub_id = "https://aus.social/@feather1952/114173031"

      assert {:ok, message} =
               Messaging.create_federated_message(%{
                 content: "reply parent",
                 visibility: "public",
                 federated: true,
                 activitypub_id: activitypub_id,
                 activitypub_url: activitypub_id,
                 remote_actor_id: actor.id
               })

      assert %{} =
               found =
               Messaging.get_message_by_activitypub_ref(activitypub_id <> "?ctx=reply#abc")

      assert found.id == message.id
    end

    test "falls back to activitypub_url variants when activitypub_id does not match" do
      actor = remote_actor_fixture()
      canonical_url = "https://mastodon.social/@alice/114173099"

      assert {:ok, message} =
               Messaging.create_federated_message(%{
                 content: "url fallback",
                 visibility: "public",
                 federated: true,
                 activitypub_id: "https://origin.example/objects/abc123",
                 activitypub_url: canonical_url,
                 remote_actor_id: actor.id
               })

      assert %{} =
               found =
               Messaging.get_message_by_activitypub_ref(canonical_url <> "?foo=bar#context")

      assert found.id == message.id
    end

    test "prefers activitypub_id match before activitypub_url match" do
      actor = remote_actor_fixture()
      ref = "https://example.net/users/alice/statuses/777"

      assert {:ok, by_id} =
               Messaging.create_federated_message(%{
                 content: "id match",
                 visibility: "public",
                 federated: true,
                 activitypub_id: ref,
                 activitypub_url: "https://example.net/@alice/777",
                 remote_actor_id: actor.id
               })

      assert {:ok, _by_url} =
               Messaging.create_federated_message(%{
                 content: "url match",
                 visibility: "public",
                 federated: true,
                 activitypub_id: "https://origin.example/objects/def456",
                 activitypub_url: ref,
                 remote_actor_id: actor.id
               })

      assert %{} = found = Messaging.get_message_by_activitypub_ref(ref)
      assert found.id == by_id.id
    end

    test "falls back to legacy rows without canonical columns populated" do
      actor = remote_actor_fixture()
      canonical_ref = "https://legacy.example/users/alice/statuses/42"

      message =
        Repo.insert!(%Message{
          content: "legacy ref",
          visibility: "public",
          federated: true,
          activitypub_id: canonical_ref <> "/?ctx=reply#fragment",
          activitypub_url: canonical_ref <> "?view=web",
          remote_actor_id: actor.id
        })

      assert %{} = found = Messaging.get_message_by_activitypub_ref(canonical_ref)
      assert found.id == message.id
    end

    test "caches missing refs and invalidates the cache when a matching federated message is created" do
      actor = remote_actor_fixture()
      ref = "https://mastodon.social/@alice/114173199?foo=bar#context"

      assert Messaging.get_message_by_activitypub_ref(ref) == nil

      assert {:ok, message} =
               Messaging.create_federated_message(%{
                 content: "arrived after miss",
                 visibility: "public",
                 federated: true,
                 activitypub_id: "https://origin.example/objects/ghi789",
                 activitypub_url: "https://mastodon.social/@alice/114173199",
                 remote_actor_id: actor.id
               })

      assert %{} = found = Messaging.get_message_by_activitypub_ref(ref)
      assert found.id == message.id
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
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----"
    })
    |> Repo.insert!()
  end
end
