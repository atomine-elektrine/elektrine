defmodule Elektrine.Messaging.ActivityPubRefLookupTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

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
