defmodule Elektrine.AccountsTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Activity, Actor, Delivery}
  alias Elektrine.Profiles

  describe "user validation" do
    test "username validation requires minimum 2 characters" do
      # Test usernames that are too short (less than 2 characters)
      short_usernames = ["a"]

      for short_name <- short_usernames do
        attrs = %{
          username: short_name,
          password: "testpassword123",
          password_confirmation: "testpassword123"
        }

        changeset = User.registration_changeset(%User{}, attrs)
        refute changeset.valid?, "#{short_name} should be rejected (too short)"
        assert %{username: [error]} = errors_on(changeset)
        assert String.contains?(error, "should be at least 2 character(s)")
      end

      # Test that 2+ character usernames work
      valid_usernames = ["ab", "xyz", "abcd", "tester", "validuser123"]

      for valid_name <- valid_usernames do
        attrs = %{
          username: valid_name,
          password: "testpassword123",
          password_confirmation: "testpassword123"
        }

        changeset = User.registration_changeset(%User{}, attrs)
        refute changeset.errors[:username], "#{valid_name} should not have username errors"
      end
    end

    test "admin registration changeset requires minimum 2 characters" do
      short_username_attrs = %{
        username: "a",
        password: "testpassword123",
        password_confirmation: "testpassword123"
      }

      changeset = User.admin_registration_changeset(%User{}, short_username_attrs)
      refute changeset.valid?
      errors = errors_on(changeset)

      assert Enum.any?(
               errors.username,
               &String.contains?(&1, "should be at least 2 character(s)")
             )
    end

    test "admin changeset validation requires minimum 2 characters" do
      # User.changeset is for settings updates, not username changes
      # Use admin_changeset which validates usernames
      short_username_attrs = %{
        username: "a"
      }

      changeset = User.admin_changeset(%User{}, short_username_attrs)
      refute changeset.valid?
      errors = errors_on(changeset)

      assert Enum.any?(
               errors.username,
               &String.contains?(&1, "should be at least 2 character(s)")
             )
    end
  end

  if Code.ensure_loaded?(Elektrine.Email.Message) and Code.ensure_loaded?(Elektrine.Email.Mailbox) do
    describe "user deletion with mailboxes" do
      test "delete_user/1 removes user's mailboxes and messages" do
        # Create a user
        {:ok, user} =
          Accounts.create_user(%{
            username: "testdel",
            password: "testpassword123",
            password_confirmation: "testpassword123"
          })

        # User creation should have created a mailbox
        mailbox = Elektrine.Repo.get_by(Elektrine.Email.Mailbox, user_id: user.id)
        assert mailbox
        assert mailbox.email == "testdel@example.com"

        # Create a message in the mailbox
        {:ok, message} =
          %Elektrine.Email.Message{}
          |> Elektrine.Email.Message.changeset(%{
            mailbox_id: mailbox.id,
            message_id: "test-message-#{System.unique_integer()}",
            from: "sender@example.com",
            to: "testdel@example.com",
            subject: "Test message",
            text_body: "Test content"
          })
          |> Elektrine.Repo.insert()

        # Verify the message exists
        assert Elektrine.Repo.get(Elektrine.Email.Message, message.id)

        # Delete the user
        {:ok, _deleted_user} = Accounts.delete_user(user)

        # Verify user is deleted
        refute Elektrine.Repo.get(User, user.id)

        # Verify mailbox is deleted
        refute Elektrine.Repo.get(Elektrine.Email.Mailbox, mailbox.id)

        # Verify message is deleted
        refute Elektrine.Repo.get(Elektrine.Email.Message, message.id)
      end
    end
  end

  describe "ActivityPub actor updates" do
    test "handle changes are rejected once set" do
      user = AccountsFixtures.user_fixture(%{username: "stablehandleuser"})

      assert {:error, changeset} = Accounts.update_user_handle(user, "newhandle")
      assert "cannot be changed once set" in errors_on(changeset).handle
    end

    test "avatar changes publish an Update to remote followers" do
      user = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture()

      assert {:ok, _follow} = Profiles.create_remote_follow(remote_actor.id, user.id)

      assert {:ok, updated_user} =
               Accounts.update_user(user, %{
                 avatar: "/uploads/avatars/new-avatar.jpg",
                 avatar_size: 12_345
               })

      actor_uri = "#{ActivityPub.instance_url()}/users/#{updated_user.username}"

      assert %Activity{id: activity_id, data: data} =
               Repo.get_by!(Activity,
                 internal_user_id: user.id,
                 activity_type: "Update",
                 object_id: actor_uri
               )

      assert get_in(data, ["object", "icon", "url"]) ==
               "#{ActivityPub.instance_url()}#{Elektrine.Uploads.avatar_url(updated_user.avatar)}"

      assert Repo.all(
               from(d in Delivery, where: d.activity_id == ^activity_id, select: d.inbox_url)
             ) == [remote_actor.inbox_url]
    end

    test "actor updates use the canonical handle actor uri" do
      user =
        AccountsFixtures.user_fixture(%{username: "avatarhandleuser"})
        |> set_handle!("avatar_handle")

      remote_actor = remote_actor_fixture()

      assert {:ok, _follow} = Profiles.create_remote_follow(remote_actor.id, user.id)

      assert {:ok, updated_user} =
               Accounts.update_user(user, %{
                 avatar: "/uploads/avatars/new-avatar.jpg",
                 avatar_size: 12_345
               })

      canonical_actor_uri = ActivityPub.actor_uri(updated_user)

      assert %Activity{} =
               Repo.get_by!(Activity,
                 internal_user_id: user.id,
                 activity_type: "Update",
                 object_id: canonical_actor_uri
               )
    end

    test "non-actor settings do not publish an Update" do
      user = AccountsFixtures.user_fixture()
      remote_actor = remote_actor_fixture()

      assert {:ok, _follow} = Profiles.create_remote_follow(remote_actor.id, user.id)
      assert {:ok, _updated_user} = Accounts.update_user(user, %{locale: "zh"})

      refute Repo.get_by(Activity, internal_user_id: user.id, activity_type: "Update")
    end
  end

  defp remote_actor_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uri: "https://fed.example/users/test#{unique}",
      username: "test#{unique}",
      domain: "fed.example",
      inbox_url: "https://fed.example/users/test#{unique}/inbox",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{}
    }

    %Actor{}
    |> Actor.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp set_handle!(user, handle) do
    user
    |> Ecto.Changeset.change(handle: handle)
    |> Repo.update!()
  end
end
