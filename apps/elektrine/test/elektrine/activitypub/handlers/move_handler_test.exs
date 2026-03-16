defmodule Elektrine.ActivityPub.Handlers.MoveHandlerTest do
  use Elektrine.DataCase, async: true

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.MoveHandler
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  describe "handle/3" do
    test "migrates local follow relationships from old actor to target actor" do
      follower = user_fixture()
      old_actor = remote_actor_fixture("old", %{"movedTo" => nil})
      new_actor = remote_actor_fixture("new", %{"alsoKnownAs" => []})

      old_actor =
        old_actor
        |> Actor.changeset(%{metadata: %{"movedTo" => new_actor.uri}})
        |> Repo.update!()

      _new_actor =
        new_actor
        |> Actor.changeset(%{"metadata" => %{"alsoKnownAs" => [old_actor.uri]}})
        |> Repo.update!()

      %Follow{}
      |> Follow.changeset(%{
        follower_id: follower.id,
        remote_actor_id: old_actor.id,
        pending: false,
        activitypub_id: "https://remote.example/activities/follow/1"
      })
      |> Repo.insert!()

      activity = %{
        "id" => "https://remote.example/activities/move/1",
        "type" => "Move",
        "actor" => old_actor.uri,
        "object" => old_actor.uri,
        "target" => new_actor.uri
      }

      assert {:ok, :moved} = MoveHandler.handle(activity, old_actor.uri, nil)

      migrated_follow =
        Follow
        |> where(
          [f],
          f.follower_id == ^follower.id and f.remote_actor_id == ^new_actor.id and
            is_nil(f.followed_id)
        )
        |> Repo.one!()

      assert migrated_follow.pending == false
      assert Repo.get_by(Follow, follower_id: follower.id, remote_actor_id: old_actor.id) == nil
    end

    test "ignores move activity when the target actor does not alias the old actor" do
      follower = user_fixture()

      old_actor =
        remote_actor_fixture("old-missing-alias", %{"movedTo" => "https://placeholder.invalid"})
        |> Actor.changeset(%{metadata: %{}})
        |> Repo.update!()

      new_actor = remote_actor_fixture("new-missing-alias")

      old_actor =
        old_actor
        |> Actor.changeset(%{metadata: %{"movedTo" => new_actor.uri}})
        |> Repo.update!()

      %Follow{}
      |> Follow.changeset(%{
        follower_id: follower.id,
        remote_actor_id: old_actor.id,
        pending: false,
        activitypub_id: "https://remote.example/activities/follow/2"
      })
      |> Repo.insert!()

      activity = %{
        "id" => "https://remote.example/activities/move/3",
        "type" => "Move",
        "actor" => old_actor.uri,
        "object" => old_actor.uri,
        "target" => new_actor.uri
      }

      assert {:ok, :ignored} = MoveHandler.handle(activity, old_actor.uri, nil)
      assert Repo.get_by(Follow, follower_id: follower.id, remote_actor_id: old_actor.id)
      refute Repo.get_by(Follow, follower_id: follower.id, remote_actor_id: new_actor.id)
    end

    test "ignores move activity when actor and object do not match" do
      old_actor = remote_actor_fixture("old-mismatch")
      new_actor = remote_actor_fixture("new-mismatch")

      activity = %{
        "id" => "https://remote.example/activities/move/2",
        "type" => "Move",
        "actor" => "https://remote.example/users/other",
        "object" => old_actor.uri,
        "target" => new_actor.uri
      }

      assert {:ok, :ignored} = MoveHandler.handle(activity, old_actor.uri, nil)
    end

    test "returns an error when referenced move actors cannot be fetched" do
      unique_id = System.unique_integer([:positive])
      actor_uri = "https://missing-#{unique_id}.invalid/users/old"

      activity = %{
        "id" => "https://missing-#{unique_id}.invalid/activities/move/1",
        "type" => "Move",
        "actor" => actor_uri,
        "object" => actor_uri,
        "target" => "https://missing-#{unique_id}.invalid/users/new"
      }

      assert {:error, :move_actor_fetch_failed} = MoveHandler.handle(activity, actor_uri, nil)
    end
  end

  defp remote_actor_fixture(suffix, metadata \\ %{}) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      uri: "https://remote.example/users/#{suffix}-#{unique_id}",
      username: "#{suffix}_#{unique_id}",
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{suffix}-#{unique_id}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: metadata
    }

    %Actor{}
    |> Actor.changeset(defaults)
    |> Repo.insert!()
  end
end
