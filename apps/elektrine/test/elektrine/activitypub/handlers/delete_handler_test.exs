defmodule Elektrine.ActivityPub.Handlers.DeleteHandlerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.DeleteHandler
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

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
