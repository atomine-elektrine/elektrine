defmodule Elektrine.ProfilesTest do
  @moduledoc """
  Tests for the Profiles context, including profile creation,
  lookup by handle, and follow/unfollow functionality.
  """
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
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

      Profiles.unfollow_user(user1.id, user2.id)
      refute Profiles.following?(user1.id, user2.id)
    end

    test "unfollowing when not following is a no-op" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      # Should not raise
      Profiles.unfollow_user(user1.id, user2.id)
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

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}_#{unique_id}"

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
