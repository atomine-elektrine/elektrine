defmodule Elektrine.ActivityPub.Handlers.AnnounceHandlerTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.AnnounceHandler
  alias Elektrine.Messaging
  alias Elektrine.Messaging.FederatedBoost
  alias Elektrine.Repo

  describe "handle/3 - Announce activity" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns error for announce of non-existent local message", %{user: _user} do
      base_url = ActivityPub.instance_url()
      booster = remote_actor_fixture("missinglocalbooster")

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => "#{base_url}/posts/99999999"
      }

      result = AnnounceHandler.handle(activity, booster.uri, nil)
      assert result == {:error, :announce_object_fetch_failed}
    end

    test "handles object reference as map with id" do
      base_url = ActivityPub.instance_url()
      booster = remote_actor_fixture("mapbooster")

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => %{"id" => "#{base_url}/posts/99999999", "type" => "Note"}
      }

      result = AnnounceHandler.handle(activity, booster.uri, nil)
      assert result == {:error, :announce_object_fetch_failed}
    end

    test "retries activity wrapper URLs when the announced object cannot be fetched" do
      booster = remote_actor_fixture("wrapperbooster")

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => "https://remote.server/activities/123"
      }

      result = AnnounceHandler.handle(activity, booster.uri, nil)
      assert result == {:error, :announce_object_fetch_failed}
    end

    test "returns a retryable error when a nested Create wrapper cannot resolve its inner object" do
      booster = remote_actor_fixture("nestedbooster")
      author = remote_actor_fixture("nestedauthor")
      wrapper_uri = "https://example.com/activities/#{System.unique_integer([:positive])}"

      wrapper_object = %{
        "id" => wrapper_uri,
        "type" => "Create",
        "actor" => author.uri,
        "object" => "http://127.0.0.1/objects/#{System.unique_integer([:positive])}"
      }

      assert {:ok, _cached_wrapper_object} =
               Elektrine.AppCache.get_object(wrapper_uri, fn -> {:ok, wrapper_object} end)

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => wrapper_uri
      }

      assert {:error, :announce_object_fetch_failed} =
               AnnounceHandler.handle(activity, booster.uri, nil)
    end

    test "inherits public visibility from nested Create wrappers" do
      booster = remote_actor_fixture("visibilitybooster")
      author = remote_actor_fixture("visibilityauthor")
      wrapper_uri = "https://example.com/activities/#{System.unique_integer([:positive])}"
      object_id = "https://example.com/objects/#{System.unique_integer([:positive])}"

      wrapper_object = %{
        "id" => wrapper_uri,
        "type" => "Create",
        "actor" => author.uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "object" => %{
          "id" => object_id,
          "type" => "Note",
          "content" => "<p>Wrapped public note</p>",
          "attributedTo" => author.uri,
          "to" => [],
          "cc" => []
        }
      }

      assert {:ok, _cached_wrapper} =
               Elektrine.AppCache.get_object(wrapper_uri, fn -> {:ok, wrapper_object} end)

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => wrapper_uri
      }

      assert {:ok, :announced} = AnnounceHandler.handle(activity, booster.uri, nil)
      assert %{visibility: "public"} = Messaging.get_message_by_activitypub_id(object_id)
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

    test "returns a retryable error when an Announce object list only contains failures" do
      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => [
          "https://remote.server/activities/123",
          %{"invalid" => "no_id"}
        ]
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      assert result == {:error, :announce_object_fetch_failed}
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

    test "unwraps nested object wrappers when handling an announce" do
      booster = remote_actor_fixture("wrapped_booster")
      message = remote_message_fixture("wrapped-announce-post")

      activity = %{
        "type" => "Announce",
        "actor" => booster.uri,
        "object" => %{
          "type" => "Create",
          "object" => %{"id" => message.activitypub_id, "type" => "Note"}
        }
      }

      assert {:ok, :announced} = AnnounceHandler.handle(activity, booster.uri, nil)
      assert Repo.get_by(FederatedBoost, message_id: message.id, remote_actor_id: booster.id)
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

    test "uses embedded Announce.object when undoing a standard Announce activity" do
      booster = remote_actor_fixture("undo_booster")
      message = remote_message_fixture("undo-announce-post")

      assert {:ok, _boost} = Messaging.create_federated_boost(message.id, booster.id)

      object = %{
        "type" => "Announce",
        "id" => "https://remote.server/announces/#{System.unique_integer([:positive])}",
        "object" => message.activitypub_id
      }

      assert {:ok, :unannounced} = AnnounceHandler.handle_undo(object, booster.uri)

      assert Repo.get_by(FederatedBoost, message_id: message.id, remote_actor_id: booster.id) ==
               nil
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

  defp remote_message_fixture(label) do
    author = remote_actor_fixture("#{label}-author")
    ap_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "#{label} content",
        visibility: "public",
        activitypub_id: ap_id,
        activitypub_url: "#{ap_id}/view",
        federated: true,
        remote_actor_id: author.id,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    message
  end
end
