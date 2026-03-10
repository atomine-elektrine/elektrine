defmodule Elektrine.ActivityPub.Handlers.UpdateHandlerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.UpdateHandler
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  test "matches a federated post by activitypub URL variant" do
    author = remote_actor_fixture("author")
    canonical_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"
    object_url = "#{canonical_id}/update"

    assert {:ok, message} =
             Messaging.create_federated_message(%{
               content: "Original content",
               visibility: "public",
               activitypub_id: canonical_id,
               activitypub_url: object_url,
               federated: true,
               remote_actor_id: author.id,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    activity = %{
      "type" => "Update",
      "actor" => author.uri,
      "object" => %{
        "id" => object_url,
        "type" => "Note",
        "content" => "<p>Updated content</p>"
      }
    }

    assert {:ok, :updated} = UpdateHandler.handle(activity, author.uri, nil)
    assert Repo.get!(Message, message.id).content == "Updated content"
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
