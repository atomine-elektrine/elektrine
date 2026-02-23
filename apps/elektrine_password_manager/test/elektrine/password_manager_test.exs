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

    test "setup_vault/2 stores verifier and marks vault configured", %{user: user} do
      refute PasswordManager.vault_configured?(user.id)

      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier")
               })

      assert PasswordManager.vault_configured?(user.id)

      assert %{"ciphertext" => _ciphertext} =
               PasswordManager.get_vault_settings(user.id).encrypted_verifier
    end

    test "create_entry/2 requires vault setup", %{user: user} do
      assert {:error, :vault_not_configured} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Blocked",
                 "encrypted_password" => encrypted_payload("nope")
               })
    end

    test "create_entry/2 stores client-encrypted payloads at rest", %{user: user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier")
               })

      attrs = %{
        "title" => "GitHub",
        "login_username" => "dev@example.com",
        "website" => "https://github.com",
        "encrypted_password" => encrypted_payload("SuperSecret123!"),
        "encrypted_notes" => encrypted_payload("MFA enabled")
      }

      assert {:ok, entry} = PasswordManager.create_entry(user.id, attrs)

      stored_entry = Repo.get!(VaultEntry, entry.id)

      assert stored_entry.title == "GitHub"

      assert stored_entry.encrypted_password["ciphertext"] ==
               attrs["encrypted_password"]["ciphertext"]

      assert stored_entry.encrypted_notes["ciphertext"] == attrs["encrypted_notes"]["ciphertext"]
    end

    test "create_entry/2 validates required encrypted payload", %{user: user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier")
               })

      attrs = %{
        "title" => "Missing Ciphertext",
        "encrypted_password" => nil
      }

      assert {:error, changeset} = PasswordManager.create_entry(user.id, attrs)
      assert {"can't be blank", _opts} = changeset.errors[:encrypted_password]
    end

    test "create_entry/2 validates payload shape", %{user: user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier")
               })

      attrs = %{
        "title" => "Bad Payload",
        "encrypted_password" => %{"ciphertext" => "abc"}
      }

      assert {:error, changeset} = PasswordManager.create_entry(user.id, attrs)

      assert {"must be a valid client-encrypted payload", _opts} =
               changeset.errors[:encrypted_password]
    end

    test "create_entry/2 validates website protocol", %{user: user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier")
               })

      attrs = %{
        "title" => "Bad Website",
        "website" => "ftp://example.com",
        "encrypted_password" => encrypted_payload("password123")
      }

      assert {:error, changeset} = PasswordManager.create_entry(user.id, attrs)
      assert {"must start with http:// or https://", _opts} = changeset.errors[:website]
    end

    test "list_entries/1 only returns entries for the user", %{user: user, other_user: other_user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier-user")
               })

      assert {:ok, _settings} =
               PasswordManager.setup_vault(other_user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier-other")
               })

      assert {:ok, _entry_1} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Main Account",
                 "encrypted_password" => encrypted_payload("one")
               })

      assert {:ok, _entry_2} =
               PasswordManager.create_entry(other_user.id, %{
                 "title" => "Other Account",
                 "encrypted_password" => encrypted_payload("two")
               })

      entries = PasswordManager.list_entries(user.id)

      assert length(entries) == 1
      assert hd(entries).title == "Main Account"
      refute Map.has_key?(hd(entries), :encrypted_password)
    end

    test "list_entries/2 can include encrypted payloads", %{user: user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier")
               })

      assert {:ok, _entry} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Email",
                 "encrypted_password" => encrypted_payload("InboxSecret!")
               })

      [entry] = PasswordManager.list_entries(user.id, include_secrets: true)
      assert is_map(entry.encrypted_password)
      assert entry.encrypted_password["algorithm"] == "AES-GCM"
    end

    test "get_entry_ciphertext/2 is scoped by user", %{user: user, other_user: other_user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(other_user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier-other")
               })

      assert {:ok, entry} =
               PasswordManager.create_entry(other_user.id, %{
                 "title" => "Hidden",
                 "encrypted_password" => encrypted_payload("ShouldNotBeVisible")
               })

      assert {:error, :not_found} = PasswordManager.get_entry_ciphertext(user.id, entry.id)
    end

    test "delete_entry/2 only deletes user-owned entries", %{user: user, other_user: other_user} do
      assert {:ok, _settings} =
               PasswordManager.setup_vault(user.id, %{
                 "encrypted_verifier" => encrypted_payload("verifier-user")
               })

      assert {:ok, entry} =
               PasswordManager.create_entry(user.id, %{
                 "title" => "Delete Me",
                 "encrypted_password" => encrypted_payload("temporary")
               })

      assert {:error, :not_found} = PasswordManager.delete_entry(other_user.id, entry.id)
      assert {:ok, _deleted} = PasswordManager.delete_entry(user.id, entry.id)
      assert {:error, :not_found} = PasswordManager.get_entry_ciphertext(user.id, entry.id)
    end
  end

  defp encrypted_payload(plaintext) do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => 210_000,
      "salt" => Base.encode64("1234567890123456"),
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext:" <> plaintext)
    }
  end
end
