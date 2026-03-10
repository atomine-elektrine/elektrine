defmodule Elektrine.ActivityPub.Handlers.FollowHandlerTest do
  use Elektrine.DataCase, async: true

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Activity, Actor}
  alias Elektrine.ActivityPub.Handlers.FollowHandler
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  describe "handle/3 - Follow activity" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns error for follow of non-existent local user" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Follow",
        "id" => "https://remote.server/activities/follow/123",
        "actor" => "https://remote.server/users/follower",
        "object" => "#{base_url}/users/nonexistentuser"
      }

      result =
        FollowHandler.handle(activity, "https://remote.server/users/follower", nil)

      assert result == {:error, :handle_follow_failed}
    end

    test "returns error for follow with non-local target" do
      activity = %{
        "type" => "Follow",
        "id" => "https://remote.server/activities/follow/123",
        "actor" => "https://remote.server/users/follower",
        "object" => "https://other.server/users/someone"
      }

      result =
        FollowHandler.handle(activity, "https://remote.server/users/follower", nil)

      assert result == {:error, :handle_follow_failed}
    end

    test "keeps duplicate pending follow requests pending without auto-accepting", %{user: user} do
      remote_actor =
        remote_actor_fixture(%{
          uri: "https://remote.server/users/pending-follower",
          username: "pending_follower",
          inbox_url: "https://remote.server/users/pending-follower/inbox"
        })

      {:ok, _follow} =
        Profiles.create_remote_follow(
          remote_actor.id,
          user.id,
          true,
          "https://remote.server/activities/follow/original"
        )

      activity = %{
        "type" => "Follow",
        "id" => "https://remote.server/activities/follow/duplicate",
        "actor" => remote_actor.uri,
        "object" => "#{ActivityPub.instance_url()}/users/#{user.username}"
      }

      assert {:ok, :pending} = FollowHandler.handle(activity, remote_actor.uri, nil)

      follow = Profiles.get_follow_by_remote_actor(remote_actor.id, user.id)
      assert follow.pending == true

      accept_count =
        Activity
        |> where([a], a.activity_type == "Accept")
        |> Repo.aggregate(:count, :id)

      assert accept_count == 0
    end

    test "accepts follow activity targeting a configured legacy local domain", %{user: user} do
      previous_profile_domains = Application.get_env(:elektrine, :profile_base_domains)

      on_exit(fn ->
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_domains)
      end)

      Application.put_env(:elektrine, :profile_base_domains, [
        ActivityPub.instance_domain(),
        "z.org"
      ])

      remote_actor =
        remote_actor_fixture(%{
          uri: "https://remote.server/users/legacy-domain-follower",
          username: "legacy_domain_follower",
          inbox_url: "https://remote.server/users/legacy-domain-follower/inbox"
        })

      legacy_base_url = ActivityPub.instance_url_for_domain("z.org")

      activity = %{
        "type" => "Follow",
        "id" => "https://remote.server/activities/follow/legacy-domain",
        "actor" => remote_actor.uri,
        "object" => "#{legacy_base_url}/users/#{user.username}"
      }

      assert {:ok, :pending} = FollowHandler.handle(activity, remote_actor.uri, nil)
      assert Profiles.get_follow_by_remote_actor(remote_actor.id, user.id)
    end
  end

  describe "handle_accept/3" do
    test "accepts a local follow only from the followed actor" do
      user = user_fixture()
      remote_actor = remote_actor_fixture(%{username: "accept_target"})
      follow_id = create_local_follow_request(user, remote_actor)

      activity = %{
        "type" => "Accept",
        "actor" => remote_actor.uri,
        "object" => follow_id
      }

      assert {:ok, :follow_accepted} =
               FollowHandler.handle_accept(activity, remote_actor.uri, nil)

      follow = Profiles.get_follow_to_remote_actor(user.id, remote_actor.id)
      assert follow.pending == false
    end

    test "rejects Accept from an actor that was not originally followed" do
      user = user_fixture()
      intended_actor = remote_actor_fixture(%{username: "intended_accept_target"})
      other_actor = remote_actor_fixture(%{username: "other_accept_target"})
      follow_id = create_local_follow_request(user, intended_actor)

      activity = %{
        "type" => "Accept",
        "actor" => other_actor.uri,
        "object" => %{"type" => "Follow", "id" => follow_id}
      }

      assert {:ok, :unauthorized} = FollowHandler.handle_accept(activity, other_actor.uri, nil)

      follow = Profiles.get_follow_to_remote_actor(user.id, intended_actor.id)
      assert follow.pending == true
    end

    test "returns :unhandled for non-Follow Accept" do
      activity = %{
        "type" => "Accept",
        "actor" => "https://remote.server/users/someone",
        "object" => %{"type" => "Something", "id" => "https://example.com/something/123"}
      }

      result = FollowHandler.handle_accept(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unhandled}
    end

    test "returns :unknown_follow for Accept of unknown Follow" do
      activity = %{
        "type" => "Accept",
        "actor" => "https://remote.server/users/someone",
        "object" => %{
          "type" => "Follow",
          "id" => "https://our.server/activities/follow/nonexistent"
        }
      }

      result = FollowHandler.handle_accept(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unknown_follow}
    end
  end

  describe "handle_reject/3" do
    test "rejects a local follow only from the followed actor" do
      user = user_fixture()
      remote_actor = remote_actor_fixture(%{username: "reject_target"})
      follow_id = create_local_follow_request(user, remote_actor)

      activity = %{
        "type" => "Reject",
        "actor" => remote_actor.uri,
        "object" => %{"type" => "Follow", "id" => follow_id}
      }

      assert {:ok, :follow_rejected} =
               FollowHandler.handle_reject(activity, remote_actor.uri, nil)

      assert is_nil(Profiles.get_follow_to_remote_actor(user.id, remote_actor.id))
    end

    test "rejects Reject from an actor that was not originally followed" do
      user = user_fixture()
      intended_actor = remote_actor_fixture(%{username: "intended_reject_target"})
      other_actor = remote_actor_fixture(%{username: "other_reject_target"})
      follow_id = create_local_follow_request(user, intended_actor)

      activity = %{
        "type" => "Reject",
        "actor" => other_actor.uri,
        "object" => %{"type" => "Follow", "id" => follow_id}
      }

      assert {:ok, :unauthorized} = FollowHandler.handle_reject(activity, other_actor.uri, nil)
      assert Profiles.get_follow_to_remote_actor(user.id, intended_actor.id)
    end

    test "returns :unhandled for non-Follow Reject" do
      activity = %{
        "type" => "Reject",
        "actor" => "https://remote.server/users/someone",
        "object" => %{"type" => "Something", "id" => "https://example.com/something/123"}
      }

      result = FollowHandler.handle_reject(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unhandled}
    end

    test "returns :unknown_follow for Reject of unknown Follow" do
      activity = %{
        "type" => "Reject",
        "actor" => "https://remote.server/users/someone",
        "object" => %{
          "type" => "Follow",
          "id" => "https://our.server/activities/follow/nonexistent"
        }
      }

      result = FollowHandler.handle_reject(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unknown_follow}
    end
  end

  describe "handle_undo/2" do
    test "returns error when remote actor cannot be fetched" do
      base_url = ActivityPub.instance_url()

      result =
        FollowHandler.handle_undo(
          %{"object" => "#{base_url}/users/someone"},
          "https://nonexistent.server/users/unfollower"
        )

      assert result == {:error, :undo_follow_failed}
    end

    test "returns :invalid for invalid undo object" do
      result = FollowHandler.handle_undo(nil, "https://remote.server/users/unfollower")
      assert result == {:ok, :invalid}
    end

    test "handles object as nested map" do
      base_url = ActivityPub.instance_url()

      result =
        FollowHandler.handle_undo(
          %{"object" => %{"id" => "#{base_url}/users/someone"}},
          "https://remote.server/users/unfollower"
        )

      assert result == {:error, :undo_follow_failed}
    end
  end

  defp remote_actor_fixture(attrs) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      uri: "https://remote.server/users/follower#{unique_id}",
      username: "follower#{unique_id}",
      domain: "remote.server",
      inbox_url: "https://remote.server/users/follower#{unique_id}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %Actor{}
    |> Actor.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp create_local_follow_request(user, remote_actor) do
    follow_id = "https://example.com/activities/#{Ecto.UUID.generate()}"
    local_actor_uri = "#{ActivityPub.instance_url()}/users/#{user.username}"

    %Follow{}
    |> Follow.changeset(%{
      follower_id: user.id,
      remote_actor_id: remote_actor.id,
      activitypub_id: follow_id,
      pending: true
    })
    |> Repo.insert!()

    %Activity{}
    |> Activity.changeset(%{
      activity_id: follow_id,
      activity_type: "Follow",
      actor_uri: local_actor_uri,
      object_id: remote_actor.uri,
      data: %{
        "id" => follow_id,
        "type" => "Follow",
        "actor" => local_actor_uri,
        "object" => remote_actor.uri
      },
      local: true,
      internal_user_id: user.id
    })
    |> Repo.insert!()

    follow_id
  end
end
