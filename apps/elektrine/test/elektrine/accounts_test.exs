defmodule Elektrine.AccountsTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User

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
      assert mailbox.email == "testdel@elektrine.com"

      # Create a message in the mailbox
      {:ok, message} =
        %Elektrine.Email.Message{}
        |> Elektrine.Email.Message.changeset(%{
          mailbox_id: mailbox.id,
          message_id: "test-message-#{System.unique_integer()}",
          from: "sender@example.com",
          to: "testdel@elektrine.com",
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
