defmodule Elektrine.ProfilesTest do
  @moduledoc """
  Tests for the Profiles context, including profile creation,
  lookup by handle, and follow/unfollow functionality.
  """
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  describe "get_profile_by_handle/1" do
    test "returns profile for valid handle" do
      user = AccountsFixtures.user_fixture()

      {:ok, profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Test User",
          is_public: true
        })

      found_profile = Profiles.get_profile_by_handle(user.handle)

      assert found_profile.id == profile.id
      assert found_profile.user.handle == user.handle
    end

    test "returns nil for non-existent handle" do
      assert Profiles.get_profile_by_handle("nonexistent_handle") == nil
    end

    test "returns nil for private profiles" do
      user = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Private User",
          is_public: false
        })

      assert Profiles.get_profile_by_handle(user.handle) == nil
    end

    test "preloads user association" do
      user = AccountsFixtures.user_fixture()

      {:ok, _profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Test User",
          is_public: true
        })

      found_profile = Profiles.get_profile_by_handle(user.handle)

      assert Ecto.assoc_loaded?(found_profile.user)
      assert found_profile.user.id == user.id
    end

    test "preloads active links ordered by position" do
      user = AccountsFixtures.user_fixture()

      {:ok, profile} =
        Profiles.create_user_profile(user.id, %{
          display_name: "Test User",
          is_public: true
        })

      # Create some profile links
      {:ok, _link1} =
        Profiles.create_profile_link(profile.id, %{
          title: "Link 1",
          url: "https://example.com/1",
          position: 2,
          is_active: true
        })

      {:ok, _link2} =
        Profiles.create_profile_link(profile.id, %{
          title: "Link 2",
          url: "https://example.com/2",
          position: 1,
          is_active: true
        })

      {:ok, _inactive_link} =
        Profiles.create_profile_link(profile.id, %{
          title: "Inactive Link",
          url: "https://example.com/inactive",
          position: 0,
          is_active: false
        })

      found_profile = Profiles.get_profile_by_handle(user.handle)

      assert Ecto.assoc_loaded?(found_profile.links)
      # Should only have active links
      assert length(found_profile.links) == 2
      # Should be ordered by position
      assert Enum.at(found_profile.links, 0).title == "Link 2"
      assert Enum.at(found_profile.links, 1).title == "Link 1"
    end
  end

  describe "follow_user/2" do
    test "creates a follow relationship" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(user1.id, user2.id)
      assert Profiles.following?(user1.id, user2.id)
    end

    test "cannot follow self" do
      user = AccountsFixtures.user_fixture()

      _result = Profiles.follow_user(user.id, user.id)

      # Should either return error or silently fail
      refute Profiles.following?(user.id, user.id)
    end

    test "following same user twice is idempotent" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)
      _result = Profiles.follow_user(user1.id, user2.id)

      # Should either succeed or return already following
      assert Profiles.following?(user1.id, user2.id)
    end
  end

  describe "unfollow_user/2" do
    test "removes a follow relationship" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)
      assert Profiles.following?(user1.id, user2.id)

      assert {:ok, :unfollowed} = Profiles.unfollow_user(user1.id, user2.id)
      refute Profiles.following?(user1.id, user2.id)
    end

    test "unfollowing when not following is a no-op" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      assert {:ok, :not_following} = Profiles.unfollow_user(user1.id, user2.id)
      refute Profiles.following?(user1.id, user2.id)
    end
  end

  describe "following?/2" do
    test "returns true when following" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)

      assert Profiles.following?(user1.id, user2.id)
    end

    test "returns false when not following" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      refute Profiles.following?(user1.id, user2.id)
    end

    test "follow relationship is directional" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user1.id, user2.id)

      assert Profiles.following?(user1.id, user2.id)
      refute Profiles.following?(user2.id, user1.id)
    end
  end

  describe "remote follow identity helpers" do
    test "resolve pending follow state from a remote actor struct" do
      viewer = AccountsFixtures.user_fixture()

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://mastodon.example/users/pending-remote",
          username: "pending-remote",
          domain: "mastodon.example",
          inbox_url: "https://mastodon.example/users/pending-remote/inbox",
          public_key: "test-public-key-pending-remote",
          manually_approves_followers: true
        })
        |> Repo.insert!()

      %Follow{}
      |> Ecto.Changeset.change(%{
        follower_id: viewer.id,
        remote_actor_id: actor.id,
        activitypub_id: "https://elektrine.test/follows/#{System.unique_integer([:positive])}",
        pending: true
      })
      |> Repo.insert!()

      assert %{pending: true} = Profiles.get_follow_to_remote_actor_by_identity(viewer.id, actor)
      assert not Profiles.following_remote_actor_by_identity?(viewer.id, actor)
    end

    test "ignores nil uri when resolving remote actor identity" do
      viewer = AccountsFixtures.user_fixture()

      actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://mastodon.example/users/no-uri-lookup",
          username: "no-uri-lookup",
          domain: "mastodon.example",
          inbox_url: "https://mastodon.example/users/no-uri-lookup/inbox",
          public_key: "test-public-key-no-uri-lookup",
          manually_approves_followers: true
        })
        |> Repo.insert!()

      %Follow{}
      |> Ecto.Changeset.change(%{
        follower_id: viewer.id,
        remote_actor_id: actor.id,
        activitypub_id: "https://elektrine.test/follows/#{System.unique_integer([:positive])}",
        pending: true
      })
      |> Repo.insert!()

      actor_without_uri = %{
        id: actor.id,
        uri: nil,
        username: actor.username,
        domain: actor.domain
      }

      assert %{pending: true} =
               Profiles.get_follow_to_remote_actor_by_identity(viewer.id, actor_without_uri)

      assert not Profiles.following_remote_actor_by_identity?(viewer.id, actor_without_uri)
    end
  end

  describe "get_follower_count/1" do
    test "returns 0 for user with no followers" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_follower_count(user.id) == 0
    end

    test "returns correct count" do
      user = AccountsFixtures.user_fixture()
      follower1 = AccountsFixtures.user_fixture()
      follower2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(follower1.id, user.id)
      {:ok, _} = Profiles.follow_user(follower2.id, user.id)

      assert Profiles.get_follower_count(user.id) == 2
    end
  end

  describe "get_following_count/1" do
    test "returns 0 for user following no one" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_following_count(user.id) == 0
    end

    test "returns correct count" do
      user = AccountsFixtures.user_fixture()
      target1 = AccountsFixtures.user_fixture()
      target2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user.id, target1.id)
      {:ok, _} = Profiles.follow_user(user.id, target2.id)

      assert Profiles.get_following_count(user.id) == 2
    end
  end

  describe "get_followers/1" do
    test "returns list of followers" do
      user = AccountsFixtures.user_fixture()
      follower1 = AccountsFixtures.user_fixture()
      follower2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(follower1.id, user.id)
      {:ok, _} = Profiles.follow_user(follower2.id, user.id)

      followers = Profiles.get_followers(user.id)

      assert length(followers) == 2
      follower_ids = Enum.map(followers, & &1.user.id)
      assert follower1.id in follower_ids
      assert follower2.id in follower_ids
    end

    test "returns empty list when no followers" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_followers(user.id) == []
    end
  end

  describe "get_following/1" do
    test "returns list of users being followed" do
      user = AccountsFixtures.user_fixture()
      target1 = AccountsFixtures.user_fixture()
      target2 = AccountsFixtures.user_fixture()

      {:ok, _} = Profiles.follow_user(user.id, target1.id)
      {:ok, _} = Profiles.follow_user(user.id, target2.id)

      following = Profiles.get_following(user.id)

      assert length(following) == 2
      following_ids = Enum.map(following, & &1.user.id)
      assert target1.id in following_ids
      assert target2.id in following_ids
    end

    test "returns empty list when not following anyone" do
      user = AccountsFixtures.user_fixture()
      assert Profiles.get_following(user.id) == []
    end
  end

  describe "list_remote_followers/1" do
    test "returns only accepted remote followers" do
      user = AccountsFixtures.user_fixture()
      accepted_actor = remote_actor_fixture("accepted")
      pending_actor = remote_actor_fixture("pending")

      {:ok, _} =
        Profiles.create_remote_follow(
          accepted_actor.id,
          user.id,
          false,
          "https://remote.server/activities/follow/#{System.unique_integer([:positive])}"
        )

      {:ok, _} =
        Profiles.create_remote_follow(
          pending_actor.id,
          user.id,
          true,
          "https://remote.server/activities/follow/#{System.unique_integer([:positive])}"
        )

      followers = Profiles.list_remote_followers(user.id)
      follower_actor_ids = Enum.map(followers, & &1.remote_actor_id)

      assert accepted_actor.id in follower_actor_ids
      refute pending_actor.id in follower_actor_ids
      assert length(follower_actor_ids) == 1
    end
  end

  describe "remote follow status" do
    test "treats legacy pending follows to auto-accepting remote actors as following" do
      user = AccountsFixtures.user_fixture()
      auto_accepting_actor = remote_actor_fixture("public", %{manually_approves_followers: false})

      approval_required_actor =
        remote_actor_fixture("private", %{manually_approves_followers: true})

      insert_local_to_remote_follow(user.id, auto_accepting_actor.id, true)
      insert_local_to_remote_follow(user.id, approval_required_actor.id, true)

      assert Profiles.following_remote_actor?(user.id, auto_accepting_actor.id)
      refute Profiles.following_remote_actor?(user.id, approval_required_actor.id)

      assert Profiles.remote_following_status_batch(user.id, [
               auto_accepting_actor.id,
               approval_required_actor.id
             ]) == [
               {auto_accepting_actor.id, :following},
               {approval_required_actor.id, :pending}
             ]

      following = Profiles.get_following(user.id)

      assert Enum.any?(
               following,
               &(&1.type == "remote" and &1.remote_actor.id == auto_accepting_actor.id)
             )

      refute Enum.any?(
               following,
               &(&1.type == "remote" and &1.remote_actor.id == approval_required_actor.id)
             )

      assert Profiles.get_following_count(user.id) == 1
    end
  end

  defp remote_actor_fixture(label, overrides \\ %{}) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}_#{unique_id}"

    %Actor{}
    |> Actor.changeset(
      Map.merge(
        %{
          uri: "https://remote.server/users/#{username}",
          username: username,
          domain: "remote.server",
          inbox_url: "https://remote.server/users/#{username}/inbox",
          public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
          last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        overrides
      )
    )
    |> Repo.insert!()
  end

  defp insert_local_to_remote_follow(follower_id, remote_actor_id, pending) do
    %Follow{}
    |> Follow.changeset(%{
      follower_id: follower_id,
      remote_actor_id: remote_actor_id,
      pending: pending,
      activitypub_id: "https://elektrine.example/activities/#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end
end
