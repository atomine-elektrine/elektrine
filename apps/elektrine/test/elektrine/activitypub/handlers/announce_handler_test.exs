defmodule Elektrine.ActivityPub.Handlers.AnnounceHandlerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.AnnounceHandler
  alias Elektrine.Messaging
  alias Elektrine.Repo

  describe "handle/3 - Announce activity" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns error for announce of non-existent local message", %{user: _user} do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => "#{base_url}/posts/99999999"
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      # Tries to fetch remote object, which fails
      assert result == {:error, :fetch_failed}
    end

    test "handles object reference as map with id" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => %{"id" => "#{base_url}/posts/99999999", "type" => "Note"}
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      # Tries to fetch remote object, which fails
      assert result == {:error, :fetch_failed}
    end

    test "ignores activity wrapper URLs" do
      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => "https://remote.server/activities/123"
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      assert result == {:ok, :ignored}
    end

    test "returns error for invalid object" do
      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => %{"invalid" => "no_id"}
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      assert result == {:error, :invalid_object}
    end

    test "handles object list by processing each entry" do
      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => [
          "https://remote.server/activities/123",
          %{"invalid" => "no_id"}
        ]
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      assert result == {:ok, :ignored}
    end

    test "matches a cached federated post by activitypub URL variant" do
      booster = remote_actor_fixture("booster")
      author = remote_actor_fixture("author")
      canonical_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"
      object_url = "#{canonical_id}/permalink"

      assert {:ok, _message} =
               Messaging.create_federated_message(%{
                 content: "Remote post",
                 visibility: "public",
                 activitypub_id: canonical_id,
                 activitypub_url: object_url,
                 federated: true,
                 remote_actor_id: author.id,
                 inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
               })

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => object_url
      }

      assert {:ok, :announced} = AnnounceHandler.handle(activity, booster.uri, nil)
    end
  end

  describe "handle_undo/2" do
    test "returns message_not_found for non-existent message" do
      base_url = ActivityPub.instance_url()

      object = %{"object" => "#{base_url}/posts/99999999"}

      result = AnnounceHandler.handle_undo(object, "https://remote.server/users/booster")
      # First tries to find message, fails because remote actor doesn't exist
      assert result == {:error, :undo_announce_failed}
    end

    test "handles nested object reference" do
      base_url = ActivityPub.instance_url()

      object = %{
        "object" => %{
          "id" => "#{base_url}/posts/99999999",
          "type" => "Note"
        }
      }

      result = AnnounceHandler.handle_undo(object, "https://remote.server/users/booster")
      assert result == {:error, :undo_announce_failed}
    end
  end

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}#{unique_id}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.server/users/#{username}",
      username: username,
      domain: "remote.server",
      inbox_url: "https://remote.server/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
