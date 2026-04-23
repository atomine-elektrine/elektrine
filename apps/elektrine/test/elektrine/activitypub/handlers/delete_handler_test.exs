defmodule Elektrine.ActivityPub.Handlers.DeleteHandlerTest do
  use Elektrine.DataCase, async: true

  if not Code.ensure_loaded?(Elektrine.Social.Hashtag) do
    @moduletag skip: "requires :elektrine_social"
  end

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.{CreateHandler, DeleteHandler}
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  test "matches a federated post by activitypub URL variant" do
    author = remote_actor_fixture("author")
    canonical_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"
    object_url = "#{canonical_id}/delete"

    assert {:ok, message} =
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
      "type" => "Delete",
      "actor" => author.uri,
      "object" => object_url
    }

    assert {:ok, :deleted} = DeleteHandler.handle(activity, author.uri, nil)
    assert Repo.get!(Message, message.id).deleted_at
  end

  test "records delete receipts for unknown objects so later Create imports are ignored" do
    author = remote_actor_fixture("deleted-before-import")
    object_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"

    delete_activity = %{
      "id" => "https://remote.server/deletes/#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => author.uri,
      "object" => object_id
    }

    assert {:ok, :delete_receipt_recorded} =
             DeleteHandler.handle(delete_activity, author.uri, nil)

    assert ActivityPub.remote_delete_recorded?(author.uri, object_id)

    create_activity = %{
      "id" => "https://remote.server/creates/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => author.uri,
      "object" => %{
        "id" => object_id,
        "type" => "Note",
        "attributedTo" => author.uri,
        "content" => "This post was already deleted",
        "published" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    assert {:ok, :ignored_deleted_object} =
             CreateHandler.handle(create_activity, author.uri, nil)

    assert is_nil(Messaging.get_message_by_activitypub_id(object_id))
  end

  test "returns a retryable error when the delete actor cannot be resolved" do
    author = remote_actor_fixture("missing-delete-author")
    object_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"

    assert {:ok, _message} =
             Messaging.create_federated_message(%{
               content: "Remote post",
               visibility: "public",
               activitypub_id: object_id,
               activitypub_url: object_id,
               federated: true,
               remote_actor_id: author.id,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    stale_uri = author.uri

    author
    |> Actor.changeset(%{uri: "https://remote.server/users/renamed-#{author.id}"})
    |> Repo.update!()

    activity = %{
      "type" => "Delete",
      "actor" => stale_uri,
      "object" => object_id
    }

    assert {:error, :delete_actor_fetch_failed} = DeleteHandler.handle(activity, stale_uri, nil)
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
