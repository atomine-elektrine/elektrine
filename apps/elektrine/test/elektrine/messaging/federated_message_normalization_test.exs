defmodule Elektrine.Messaging.FederatedMessageNormalizationTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging

  describe "create_federated_message/1 normalization" do
    test "truncates titles longer than varchar limit" do
      actor = remote_actor_fixture()
      long_title = String.duplicate("T", 320)

      assert {:ok, message} =
               actor
               |> federated_attrs(%{title: long_title})
               |> Messaging.create_federated_message()

      assert String.length(message.title) == 255
      assert message.title == String.slice(long_title, 0, 255)
    end

    test "drops media URLs that exceed varchar limit" do
      actor = remote_actor_fixture()
      short_url = "https://remote.example/media/image.jpg"
      long_url = "https://remote.example/media/" <> String.duplicate("a", 280)

      assert {:ok, message} =
               actor
               |> federated_attrs(%{media_urls: [short_url, long_url]})
               |> Messaging.create_federated_message()

      assert message.media_urls == [short_url]
    end
  end

  defp federated_attrs(actor, overrides) do
    unique = System.unique_integer([:positive])

    defaults = %{
      content: "federated content",
      visibility: "public",
      activitypub_id: "https://remote.example/notes/#{unique}",
      activitypub_url: "https://remote.example/@alice/#{unique}",
      remote_actor_id: actor.id,
      media_urls: []
    }

    Map.merge(defaults, overrides)
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
