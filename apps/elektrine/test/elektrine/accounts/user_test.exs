defmodule Elektrine.Accounts.UserTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts.User
  import Ecto.Changeset

  describe "notification preference fields" do
    test "default notification preferences are true" do
      user = %User{}
      assert user.notify_on_new_follower == true
      assert user.notify_on_direct_message == true
      assert user.notify_on_mention == true
    end

    test "changeset accepts notification preference fields" do
      user = %User{}

      attrs = %{
        notify_on_new_follower: false,
        notify_on_direct_message: false,
        notify_on_mention: false
      }

      changeset = User.changeset(user, attrs)

      assert changeset.valid?
      assert get_change(changeset, :notify_on_new_follower) == false
      assert get_change(changeset, :notify_on_direct_message) == false
      assert get_change(changeset, :notify_on_mention) == false
    end

    test "notification preferences must be boolean" do
      user = %User{}

      # These should be coerced to boolean
      attrs = %{
        notify_on_new_follower: "true",
        notify_on_direct_message: "false"
      }

      changeset = User.changeset(user, attrs)
      assert changeset.valid?
    end
  end

  describe "privacy setting fields" do
    test "default privacy settings" do
      user = %User{}
      assert user.profile_visibility == "public"
      assert user.allow_group_adds_from == "everyone"
      assert user.allow_direct_messages_from == "everyone"
      assert user.allow_mentions_from == "everyone"
    end

    test "changeset accepts privacy settings" do
      user = %User{}

      attrs = %{
        profile_visibility: "private",
        allow_group_adds_from: "followers",
        allow_direct_messages_from: "nobody",
        allow_mentions_from: "followers"
      }

      changeset = User.changeset(user, attrs)

      assert changeset.valid?
      assert get_change(changeset, :profile_visibility) == "private"
      assert get_change(changeset, :allow_group_adds_from) == "followers"
      assert get_change(changeset, :allow_direct_messages_from) == "nobody"
      assert get_change(changeset, :allow_mentions_from) == "followers"
    end

    test "profile_visibility validates inclusion" do
      user = %User{}

      # Valid values
      for value <- ["public", "followers", "private"] do
        changeset = User.changeset(user, %{profile_visibility: value})
        assert changeset.valid?, "#{value} should be valid"
      end

      # Invalid value
      changeset = User.changeset(user, %{profile_visibility: "invalid"})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).profile_visibility
    end

    test "allow_group_adds_from validates inclusion" do
      user = %User{}

      # Valid values
      for value <- ["everyone", "followers", "nobody"] do
        changeset = User.changeset(user, %{allow_group_adds_from: value})
        assert changeset.valid?, "#{value} should be valid"
      end

      # Invalid value
      changeset = User.changeset(user, %{allow_group_adds_from: "invalid"})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).allow_group_adds_from
    end

    test "allow_direct_messages_from validates inclusion" do
      user = %User{}

      # Valid values
      for value <- ["everyone", "followers", "nobody"] do
        changeset = User.changeset(user, %{allow_direct_messages_from: value})
        assert changeset.valid?, "#{value} should be valid"
      end

      # Invalid value
      changeset = User.changeset(user, %{allow_direct_messages_from: "invalid"})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).allow_direct_messages_from
    end

    test "allow_mentions_from validates inclusion" do
      user = %User{}

      # Valid values
      for value <- ["everyone", "followers", "nobody"] do
        changeset = User.changeset(user, %{allow_mentions_from: value})
        assert changeset.valid?, "#{value} should be valid"
      end

      # Invalid value
      changeset = User.changeset(user, %{allow_mentions_from: "invalid"})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).allow_mentions_from
    end
  end

  describe "combined settings" do
    test "changeset can update both privacy and notification settings together" do
      user = %User{}

      attrs = %{
        # Privacy settings
        profile_visibility: "followers",
        allow_group_adds_from: "followers",
        allow_direct_messages_from: "followers",
        allow_mentions_from: "followers",
        # Notification settings
        notify_on_new_follower: false,
        notify_on_direct_message: true,
        notify_on_mention: false
      }

      changeset = User.changeset(user, attrs)

      assert changeset.valid?

      # Check privacy settings
      assert get_change(changeset, :profile_visibility) == "followers"
      assert get_change(changeset, :allow_group_adds_from) == "followers"
      assert get_change(changeset, :allow_direct_messages_from) == "followers"
      assert get_change(changeset, :allow_mentions_from) == "followers"

      # Check notification settings
      assert get_change(changeset, :notify_on_new_follower) == false
      # notify_on_direct_message is true which is the default, so it won't be a change
      assert get_field(changeset, :notify_on_direct_message) == true
      assert get_change(changeset, :notify_on_mention) == false
    end
  end
end
