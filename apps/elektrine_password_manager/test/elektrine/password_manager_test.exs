defmodule Elektrine.PasswordManagerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.PasswordManager
  alias Elektrine.PasswordManager.VaultEntry
  alias Elektrine.Repo

  describe "vault entries" do
    setup do
      user = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()

      %{user: user, other_user: other_user}
    end

    test "create_entry/2 stores encrypted data at rest", %{user: user} do
      attrs = %{
        "title" => "GitHub",
        "login_username" => "dev@example.com",
        "website" => "https://github.com",
        "password" => "SuperSecret123!",
        "notes" => "MFA enabled"
      }

      assert {:ok, entry} = PasswordManager.create_entry(user.id, attrs)

      stored_entry = Repo.get!(VaultEntry, entry.id)

      assert stored_entry.title == "GitHub"
      assert stored_entry.encrypted_password["encrypted_data"] != attrs["password"]
      assert stored_entry.encrypted_notes["encrypted_data"] != attrs["notes"]
    end

    test "create_entry/2 validates required password", %{user: user} do
      attrs = %{
        "title" => "No Password Entry",
        "password" => ""
      }

      assert {:error, changeset} = PasswordManager.create_entry(user.id, attrs)
      assert {"can't be blank", _opts} = changeset.errors[:password]
    end

    test "create_entry/2 validates website protocol", %{user: user} do
      attrs = %{
        "title" => "Bad Website",
        "website" => "ftp://example.com",
        "password" => "password123"
      }

      assert {:error, changeset} = PasswordManager.create_entry(user.id, attrs)
      assert {"must start with http:// or https://", _opts} = changeset.errors[:website]
    end

    test "list_entries/1 only returns entries for the user", %{user: user, other_user: other_user} do
      assert {:ok, _entry_1} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Main Account",
                 "password" => "one"
               })

      assert {:ok, _entry_2} =
               PasswordManager.create_entry(other_user.id, %{
                 "title" => "Other Account",
                 "password" => "two"
               })

      entries = PasswordManager.list_entries(user.id)

      assert length(entries) == 1
      assert hd(entries).title == "Main Account"
    end

    test "get_entry/2 decrypts password and notes", %{user: user} do
      assert {:ok, entry} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Email",
                 "password" => "InboxSecret!",
                 "notes" => "Recovery email on file"
               })

      assert {:ok, decrypted} = PasswordManager.get_entry(user.id, entry.id)
      assert decrypted.password == "InboxSecret!"
      assert decrypted.notes == "Recovery email on file"
    end

    test "get_entry/2 is scoped by user", %{user: user, other_user: other_user} do
      assert {:ok, entry} =
               PasswordManager.create_entry(other_user.id, %{
                 "title" => "Hidden",
                 "password" => "ShouldNotBeVisible"
               })

      assert {:error, :not_found} = PasswordManager.get_entry(user.id, entry.id)
    end

    test "delete_entry/2 only deletes user-owned entries", %{user: user, other_user: other_user} do
      assert {:ok, entry} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Delete Me",
                 "password" => "temporary"
               })

      assert {:error, :not_found} = PasswordManager.delete_entry(other_user.id, entry.id)
      assert {:ok, _deleted} = PasswordManager.delete_entry(user.id, entry.id)
      assert {:error, :not_found} = PasswordManager.get_entry(user.id, entry.id)
    end
  end
end
