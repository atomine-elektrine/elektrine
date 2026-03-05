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
      old_actor = remote_actor_fixture("old")
      new_actor = remote_actor_fixture("new")

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
  end

  defp remote_actor_fixture(suffix) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      uri: "https://remote.example/users/#{suffix}-#{unique_id}",
      username: "#{suffix}_#{unique_id}",
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{suffix}-#{unique_id}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %Actor{}
    |> Actor.changeset(defaults)
    |> Repo.insert!()
  end
end
