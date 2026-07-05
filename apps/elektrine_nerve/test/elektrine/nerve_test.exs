defmodule Elektrine.NerveTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Nerve
  alias Elektrine.Nerve.NerveEntry
  alias Elektrine.Repo

  describe "nerve entries" do
    setup do
      user = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()

      %{user: user, other_user: other_user}
    end

    test "create_entry/2 stores client-encrypted payloads at rest", %{user: user} do
      attrs = %{
        "title" => "GitHub",
        "login_username" => "dev@example.com",
        "website" => "https://github.com",
        "encrypted_metadata" => encrypted_payload("metadata"),
        "encrypted_password" => encrypted_payload("SuperSecret123!"),
        "encrypted_notes" => encrypted_payload("MFA enabled")
      }

      assert {:ok, entry} = Nerve.create_entry(user.id, attrs)

      stored_entry = Repo.get!(NerveEntry, entry.id)

      assert stored_entry.title == "Encrypted entry"

      assert stored_entry.encrypted_metadata["ciphertext"] ==
               attrs["encrypted_metadata"]["ciphertext"]

      assert stored_entry.encrypted_password["ciphertext"] ==
               attrs["encrypted_password"]["ciphertext"]

      assert stored_entry.encrypted_notes["ciphertext"] == attrs["encrypted_notes"]["ciphertext"]
    end

    test "create_entry/2 stores encrypted metadata without plaintext metadata", %{user: user} do
      attrs = %{
        "title" => "GitHub",
        "login_username" => "dev@example.com",
        "website" => "https://github.com",
        "encrypted_metadata" => encrypted_payload("metadata"),
        "encrypted_password" => encrypted_payload("SuperSecret123!")
      }

      assert {:ok, entry} = Nerve.create_entry(user.id, attrs)

      stored_entry = Repo.get!(NerveEntry, entry.id)

      assert stored_entry.title == "Encrypted entry"
      assert is_nil(stored_entry.login_username)
      assert is_nil(stored_entry.website)

      assert stored_entry.encrypted_metadata["ciphertext"] ==
               attrs["encrypted_metadata"]["ciphertext"]
    end

    test "create_entry/2 requires encrypted metadata", %{user: user} do
      attrs = %{
        "title" => "GitHub",
        "encrypted_password" => encrypted_payload("SuperSecret123!")
      }

      assert {:error, changeset} = Nerve.create_entry(user.id, attrs)
      assert {"can't be blank", _opts} = changeset.errors[:encrypted_metadata]
    end

    test "create_entry/2 validates required encrypted payload", %{user: user} do
      attrs = %{
        "title" => "Missing Ciphertext",
        "encrypted_metadata" => encrypted_payload("metadata"),
        "encrypted_password" => nil
      }

      assert {:error, changeset} = Nerve.create_entry(user.id, attrs)
      assert {"can't be blank", _opts} = changeset.errors[:encrypted_password]
    end

    test "create_entry/2 validates payload shape", %{user: user} do
      attrs = %{
        "title" => "Bad Payload",
        "encrypted_metadata" => encrypted_payload("metadata"),
        "encrypted_password" => %{"ciphertext" => "abc"}
      }

      assert {:error, changeset} = Nerve.create_entry(user.id, attrs)

      assert {"must be a valid client-encrypted payload", _opts} =
               changeset.errors[:encrypted_password]
    end

    test "form changeset validates website protocol", %{user: user} do
      changeset =
        NerveEntry.form_changeset(%NerveEntry{}, %{
          "title" => "Bad Website",
          "website" => "ftp://example.com",
          "user_id" => user.id
        })

      assert {"must be a safe http:// or https:// URL", _opts} = changeset.errors[:website]
    end

    test "form changeset rejects unsafe website URLs", %{user: user} do
      for website <- [
            "javascript:alert(1)",
            "https://user:pass@example.com",
            "https://example.com\r\nLocation:https://evil.test",
            "//example.com"
          ] do
        changeset =
          NerveEntry.form_changeset(%NerveEntry{}, %{
            "title" => "Bad Website",
            "website" => website,
            "user_id" => user.id
          })

        assert {"must be a safe http:// or https:// URL", _opts} = changeset.errors[:website]
      end
    end

    test "form changeset accepts safe website URLs", %{user: user} do
      changeset =
        NerveEntry.form_changeset(%NerveEntry{}, %{
          "title" => "Safe Website",
          "website" => " https://example.com/path?x=1 ",
          "user_id" => user.id
        })

      assert changeset.valid?
      assert get_change(changeset, :website) == "https://example.com/path?x=1"
    end

    test "list_entries/1 only returns entries for the user", %{user: user, other_user: other_user} do
      assert {:ok, _entry_1} =
               Nerve.create_entry(user.id, %{
                 "title" => "Main Account",
                 "encrypted_metadata" => encrypted_payload("metadata-user"),
                 "encrypted_password" => encrypted_payload("one")
               })

      assert {:ok, _entry_2} =
               Nerve.create_entry(other_user.id, %{
                 "title" => "Other Account",
                 "encrypted_metadata" => encrypted_payload("metadata-other"),
                 "encrypted_password" => encrypted_payload("two")
               })

      entries = Nerve.list_entries(user.id)

      assert length(entries) == 1
      assert hd(entries).title == "Encrypted entry"
      refute Map.has_key?(hd(entries), :encrypted_password)
    end

    test "list_entries/2 can include encrypted payloads", %{user: user} do
      assert {:ok, _entry} =
               Nerve.create_entry(user.id, %{
                 "title" => "Email",
                 "encrypted_metadata" => encrypted_payload("metadata"),
                 "encrypted_password" => encrypted_payload("InboxSecret!")
               })

      [entry] = Nerve.list_entries(user.id, include_secrets: true)
      assert is_map(entry.encrypted_password)
      assert entry.encrypted_password["algorithm"] == "AES-GCM"
    end

    test "get_entry_ciphertext/2 is scoped by user", %{user: user, other_user: other_user} do
      assert {:ok, entry} =
               Nerve.create_entry(other_user.id, %{
                 "title" => "Hidden",
                 "encrypted_metadata" => encrypted_payload("metadata"),
                 "encrypted_password" => encrypted_payload("ShouldNotBeVisible")
               })

      assert {:error, :not_found} = Nerve.get_entry_ciphertext(user.id, entry.id)
    end

    test "update_entry/3 updates client-encrypted payloads for the owner", %{user: user} do
      assert {:ok, entry} =
               Nerve.create_entry(user.id, %{
                 "title" => "Email",
                 "login_username" => "old@example.com",
                 "website" => "https://mail.example.com",
                 "encrypted_metadata" => encrypted_payload("old-metadata"),
                 "encrypted_password" => encrypted_payload("old-password")
               })

      assert {:ok, updated_entry} =
               Nerve.update_entry(user.id, entry.id, %{
                 "title" => "Email Account",
                 "login_username" => "new@example.com",
                 "website" => "https://mail.example.com",
                 "encrypted_metadata" => encrypted_payload("new-metadata"),
                 "encrypted_password" => encrypted_payload("new-password"),
                 "encrypted_notes" => encrypted_payload("rotated")
               })

      assert updated_entry.title == "Encrypted entry"
      assert is_nil(updated_entry.login_username)

      stored_entry = Repo.get!(NerveEntry, entry.id)

      assert stored_entry.encrypted_password["ciphertext"] ==
               encrypted_payload("new-password")["ciphertext"]
    end

    test "update_entry/3 is scoped by user", %{user: user, other_user: other_user} do
      assert {:ok, entry} =
               Nerve.create_entry(other_user.id, %{
                 "title" => "Hidden",
                 "encrypted_metadata" => encrypted_payload("metadata"),
                 "encrypted_password" => encrypted_payload("secret")
               })

      assert {:error, :not_found} =
               Nerve.update_entry(user.id, entry.id, %{
                 "title" => "Nope",
                 "encrypted_metadata" => encrypted_payload("metadata"),
                 "encrypted_password" => encrypted_payload("updated")
               })
    end

    test "delete_entry/2 only deletes user-owned entries", %{user: user, other_user: other_user} do
      assert {:ok, entry} =
               Nerve.create_entry(user.id, %{
                 "title" => "Delete Me",
                 "encrypted_metadata" => encrypted_payload("metadata"),
                 "encrypted_password" => encrypted_payload("temporary")
               })

      assert {:error, :not_found} = Nerve.delete_entry(other_user.id, entry.id)
      assert {:ok, _deleted} = Nerve.delete_entry(user.id, entry.id)
      assert {:error, :not_found} = Nerve.get_entry_ciphertext(user.id, entry.id)
    end
  end

  # Entries are encrypted under the master key's Nerve subkey (keyed AES-256-GCM);
  # the envelope is {algorithm, iv, ciphertext}.
  defp encrypted_payload(plaintext) do
    %{
      "version" => 2,
      "algorithm" => "AES-GCM",
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext:" <> plaintext)
    }
  end
end
