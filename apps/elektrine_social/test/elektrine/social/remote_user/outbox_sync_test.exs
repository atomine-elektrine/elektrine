defmodule ElektrineSocial.RemoteUser.OutboxSyncTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias ElektrineSocial.RemoteUser.OutboxSync

  test "does not create followers-only posts from a remote outbox" do
    remote_actor = remote_actor_fixture()
    activitypub_id = "https://#{remote_actor.domain}/posts/#{System.unique_integer([:positive])}"

    posts = [
      %{
        "id" => activitypub_id,
        "type" => "Note",
        "content" => "Followers only",
        "attributedTo" => remote_actor.uri,
        "to" => ["https://#{remote_actor.domain}/users/#{remote_actor.username}/followers"],
        "cc" => []
      }
    ]

    assert [] = OutboxSync.store_outbox_posts(posts, remote_actor)
    assert is_nil(Messaging.get_message_by_activitypub_ref(activitypub_id))
  end

  test "refreshing an existing cached post corrects non-public visibility and hides it" do
    remote_actor = remote_actor_fixture()
    activitypub_id = "https://#{remote_actor.domain}/posts/#{System.unique_integer([:positive])}"

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "Previously imported as public",
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id
      })

    posts = [
      %{
        "id" => activitypub_id,
        "type" => "Note",
        "content" => "Actually followers only",
        "attributedTo" => remote_actor.uri,
        "to" => ["https://#{remote_actor.domain}/users/#{remote_actor.username}/followers"],
        "cc" => []
      }
    ]

    assert [] = OutboxSync.store_outbox_posts(posts, remote_actor)

    refreshed = Repo.reload!(message)
    assert refreshed.visibility == "followers"
  end

  defp remote_actor_fixture do
    unique = System.unique_integer([:positive])
    domain = "remote#{unique}.example"
    username = "alice#{unique}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "test-public-key-#{unique}",
      actor_type: "Person"
    })
    |> Repo.insert!()
  end
end
