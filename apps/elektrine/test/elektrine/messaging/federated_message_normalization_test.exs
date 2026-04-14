defmodule Elektrine.Messaging.FederatedMessageNormalizationTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message

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

    test "coerces structured activitypub_url values before casting" do
      actor = remote_actor_fixture()

      canonical_url =
        "https://bsky.brid.gy/convert/ap/at://did:plc:pak3r4f5v4zu4jzo772y2iep/app.bsky.feed.post/3mjdqze7vpc2d"

      assert {:ok, message} =
               actor
               |> federated_attrs(%{
                 activitypub_url: [
                   %{"type" => "Link", "href" => canonical_url}
                 ]
               })
               |> Messaging.create_federated_message()

      assert message.activitypub_url == canonical_url
    end

    test "preserves federated vote counters" do
      actor = remote_actor_fixture()

      assert {:ok, message} =
               actor
               |> federated_attrs(%{
                 like_count: 7,
                 upvotes: 7,
                 downvotes: 2,
                 score: 5
               })
               |> Messaging.create_federated_message()

      assert message.like_count == 7
      assert message.upvotes == 7
      assert message.downvotes == 2
      assert message.score == 5
    end
  end

  describe "federated_changeset/2 normalization on updates" do
    test "truncates refreshed titles and drops oversized media URLs" do
      actor = remote_actor_fixture()
      long_title = String.duplicate("T", 320)
      short_url = "https://remote.example/media/image.jpg"
      long_url = "https://remote.example/media/" <> String.duplicate("a", 280)

      assert {:ok, message} =
               actor
               |> federated_attrs(%{title: nil, media_urls: []})
               |> Messaging.create_federated_message()

      changeset =
        Message.federated_changeset(message, %{
          title: long_title,
          media_urls: [short_url, long_url]
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :title) == String.slice(long_title, 0, 255)
      assert Ecto.Changeset.get_change(changeset, :media_urls) == [short_url]
    end

    test "coerces structured activitypub_url values on updates" do
      actor = remote_actor_fixture()
      canonical_url = "https://remote.example/notes/updated-url"

      assert {:ok, message} =
               actor
               |> federated_attrs(%{activitypub_url: nil})
               |> Messaging.create_federated_message()

      changeset =
        Message.federated_changeset(message, %{
          activitypub_url: [%{"href" => canonical_url}]
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :activitypub_url) == canonical_url
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
