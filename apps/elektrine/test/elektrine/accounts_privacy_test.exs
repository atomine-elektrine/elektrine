defmodule Elektrine.AccountsPrivacyTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts
  import Elektrine.AccountsFixtures

  describe "privacy settings" do
    setup do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, user: user, other_user: other_user}
    end

    test "default privacy settings are set correctly", %{user: user} do
      assert user.profile_visibility == "public"
      assert user.allow_group_adds_from == "everyone"
      assert user.allow_direct_messages_from == "everyone"
      assert user.allow_mentions_from == "everyone"
    end

    test "update_user can change privacy settings", %{user: user} do
      attrs = %{
        profile_visibility: "private",
        allow_group_adds_from: "followers",
        allow_direct_messages_from: "nobody",
        allow_mentions_from: "followers"
      }

      assert {:ok, updated_user} = Accounts.update_user(user, attrs)
      assert updated_user.profile_visibility == "private"
      assert updated_user.allow_group_adds_from == "followers"
      assert updated_user.allow_direct_messages_from == "nobody"
      assert updated_user.allow_mentions_from == "followers"
    end

    test "privacy settings validate allowed values", %{user: user} do
      # Invalid profile visibility
      assert {:error, changeset} = Accounts.update_user(user, %{profile_visibility: "invalid"})
      assert "is invalid" in errors_on(changeset).profile_visibility

      # Invalid allow_group_adds_from
      assert {:error, changeset} = Accounts.update_user(user, %{allow_group_adds_from: "invalid"})
      assert "is invalid" in errors_on(changeset).allow_group_adds_from
    end
  end

  describe "can_view_profile?/2" do
    setup do
      public_user = user_fixture(%{profile_visibility: "public"})
      followers_only_user = user_fixture(%{profile_visibility: "followers"})
      private_user = user_fixture(%{profile_visibility: "private"})
      viewer = user_fixture()

      {:ok,
       public_user: public_user,
       followers_only_user: followers_only_user,
       private_user: private_user,
       viewer: viewer}
    end

    test "public profile can be viewed by anyone", %{public_user: user, viewer: viewer} do
      assert {:ok, :allowed} = Accounts.can_view_profile?(user, viewer)
      assert {:ok, :allowed} = Accounts.can_view_profile?(user, nil)
    end

    test "private profile can only be viewed by owner", %{private_user: user, viewer: viewer} do
      assert {:error, :privacy_restriction} = Accounts.can_view_profile?(user, viewer)
      assert {:error, :privacy_restriction} = Accounts.can_view_profile?(user, nil)
      assert {:ok, :allowed} = Accounts.can_view_profile?(user, user)
    end

    test "followers-only profile requires following relationship", %{
      followers_only_user: user,
      viewer: viewer
    } do
      # Non-follower cannot view
      assert {:error, :privacy_restriction} = Accounts.can_view_profile?(user, viewer)
      assert {:error, :privacy_restriction} = Accounts.can_view_profile?(user, nil)

      # Owner can always view their own profile
      assert {:ok, :allowed} = Accounts.can_view_profile?(user, user)

      # After following, viewer can see the profile
      # Note: This assumes a follow_user function exists in Profiles
      # You may need to adjust based on your actual implementation
      {:ok, _} = Elektrine.Profiles.follow_user(viewer.id, user.id)
      assert {:ok, :allowed} = Accounts.can_view_profile?(user, viewer)
    end
  end

  describe "can_add_to_group?/2" do
    setup do
      everyone_user = user_fixture(%{allow_group_adds_from: "everyone"})
      followers_only_user = user_fixture(%{allow_group_adds_from: "followers"})
      nobody_user = user_fixture(%{allow_group_adds_from: "nobody"})
      requester = user_fixture()

      {:ok,
       everyone_user: everyone_user,
       followers_only_user: followers_only_user,
       nobody_user: nobody_user,
       requester: requester}
    end

    test "everyone setting allows all users", %{everyone_user: user, requester: requester} do
      assert {:ok, :allowed} = Accounts.can_add_to_group?(user, requester)
    end

    test "nobody setting blocks all except self", %{nobody_user: user, requester: requester} do
      assert {:error, :privacy_restriction} = Accounts.can_add_to_group?(user, requester)
      assert {:ok, :allowed} = Accounts.can_add_to_group?(user, user)
    end

    test "followers setting requires following relationship", %{
      followers_only_user: user,
      requester: requester
    } do
      # Non-follower cannot add
      assert {:error, :privacy_restriction} = Accounts.can_add_to_group?(user, requester)

      # Owner can add themselves
      assert {:ok, :allowed} = Accounts.can_add_to_group?(user, user)

      # After following, requester can add user
      {:ok, _} = Elektrine.Profiles.follow_user(requester.id, user.id)
      assert {:ok, :allowed} = Accounts.can_add_to_group?(user, requester)
    end
  end

  describe "can_send_direct_message?/2" do
    setup do
      everyone_user = user_fixture(%{allow_direct_messages_from: "everyone"})
      followers_only_user = user_fixture(%{allow_direct_messages_from: "followers"})
      nobody_user = user_fixture(%{allow_direct_messages_from: "nobody"})
      sender = user_fixture()

      {:ok,
       everyone_user: everyone_user,
       followers_only_user: followers_only_user,
       nobody_user: nobody_user,
       sender: sender}
    end

    test "everyone setting allows all users", %{everyone_user: user, sender: sender} do
      assert {:ok, :allowed} = Accounts.can_send_direct_message?(user, sender)
    end

    test "nobody setting blocks all except self", %{nobody_user: user, sender: sender} do
      assert {:error, :privacy_restriction} = Accounts.can_send_direct_message?(user, sender)
      assert {:ok, :allowed} = Accounts.can_send_direct_message?(user, user)
    end

    test "followers setting requires following relationship", %{
      followers_only_user: user,
      sender: sender
    } do
      # Non-follower cannot send DM
      assert {:error, :privacy_restriction} = Accounts.can_send_direct_message?(user, sender)

      # User can message themselves
      assert {:ok, :allowed} = Accounts.can_send_direct_message?(user, user)

      # After following, sender can send DM
      {:ok, _} = Elektrine.Profiles.follow_user(sender.id, user.id)
      assert {:ok, :allowed} = Accounts.can_send_direct_message?(user, sender)
    end
  end

  describe "can_mention?/2" do
    setup do
      everyone_user = user_fixture(%{allow_mentions_from: "everyone"})
      followers_only_user = user_fixture(%{allow_mentions_from: "followers"})
      nobody_user = user_fixture(%{allow_mentions_from: "nobody"})
      mentioner = user_fixture()

      {:ok,
       everyone_user: everyone_user,
       followers_only_user: followers_only_user,
       nobody_user: nobody_user,
       mentioner: mentioner}
    end

    test "everyone setting allows all users", %{everyone_user: user, mentioner: mentioner} do
      assert {:ok, :allowed} = Accounts.can_mention?(user, mentioner)
    end

    test "nobody setting blocks all except self", %{nobody_user: user, mentioner: mentioner} do
      assert {:error, :privacy_restriction} = Accounts.can_mention?(user, mentioner)
      assert {:ok, :allowed} = Accounts.can_mention?(user, user)
    end

    test "followers setting requires following relationship", %{
      followers_only_user: user,
      mentioner: mentioner
    } do
      # Non-follower cannot mention
      assert {:error, :privacy_restriction} = Accounts.can_mention?(user, mentioner)

      # User can mention themselves
      assert {:ok, :allowed} = Accounts.can_mention?(user, user)

      # After following, mentioner can mention user
      {:ok, _} = Elektrine.Profiles.follow_user(mentioner.id, user.id)
      assert {:ok, :allowed} = Accounts.can_mention?(user, mentioner)
    end
  end
end
