defmodule Elektrine.Email.MailboxPrivateStorageTest do
  use Elektrine.DataCase

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Repo

  test "create_message stores encrypted message and attachment payloads for private mailboxes" do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Launch plans",
        text_body: "This should stay private",
        html_body: "<p>This should stay private</p>",
        message_id: "<private-#{System.unique_integer([:positive])}@example.com>",
        attachments: %{
          "0" => %{
            "filename" => "plans.txt",
            "content_type" => "text/plain",
            "encoding" => "base64",
            "data" => Base.encode64("launch details"),
            "size" => 14
          }
        }
      })

    stored_message = Repo.get!(Email.Message, message.id)
    stored_attachment = stored_message.attachments["0"]

    assert message.subject == "Encrypted message"
    assert stored_message.subject == "Encrypted message"
    assert is_nil(stored_message.text_body)
    assert is_nil(stored_message.html_body)
    assert stored_message.search_index == []
    assert payload_value(stored_message.client_encrypted_payload, "ciphertext", :ciphertext)
    assert payload_value(stored_message.client_encrypted_payload, "encrypted_key", :encrypted_key)
    assert stored_attachment["filename"] == "Encrypted attachment"
    assert stored_attachment["content_type"] == "application/octet-stream"
    assert stored_attachment["size"] == 14
    assert is_map(stored_attachment["private_encrypted_payload"])
    refute Map.has_key?(stored_attachment, "data")
  end

  test "save_draft updates stay encrypted for private mailboxes" do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, draft} =
      Email.save_draft(%{
        mailbox_id: mailbox.id,
        from: mailbox.email,
        to: "draft@example.com",
        subject: "Draft one",
        text_body: "Initial body",
        html_body: "<p>Initial body</p>"
      })

    {:ok, updated_draft} =
      Email.save_draft(
        %{
          mailbox_id: mailbox.id,
          from: mailbox.email,
          to: "draft@example.com",
          subject: "Draft two",
          text_body: "Updated body",
          html_body: "<p>Updated body</p>",
          message_id: draft.message_id
        },
        draft.id
      )

    stored_draft = Repo.get!(Email.Message, updated_draft.id)

    assert stored_draft.subject == "Encrypted message"
    assert is_nil(stored_draft.text_body)
    assert is_nil(stored_draft.html_body)
    assert payload_value(stored_draft.client_encrypted_payload, "ciphertext", :ciphertext)
  end

  test "mailbox unlock mode detects account password payloads and preserves legacy default" do
    legacy_mailbox = %Mailbox{
      private_storage_public_key: public_key_pem(),
      private_storage_wrapped_private_key: wrapped_payload(),
      private_storage_verifier: wrapped_payload()
    }

    account_password_mailbox = %Mailbox{
      private_storage_public_key: public_key_pem(),
      private_storage_wrapped_private_key:
        Map.put(wrapped_payload(), "unlock_mode", "account_password"),
      private_storage_verifier: Map.put(wrapped_payload(), "unlock_mode", "account_password")
    }

    assert Mailbox.private_storage_unlock_mode(legacy_mailbox) == "separate_passphrase"
    assert Mailbox.private_storage_unlock_mode(account_password_mailbox) == "account_password"
    assert Mailbox.private_storage_account_password?(account_password_mailbox)
  end

  defp private_mailbox_fixture(user) do
    mailbox =
      Email.get_user_mailbox(user.id) ||
        case Email.ensure_user_has_mailbox(user) do
          {:ok, mailbox} -> mailbox
          mailbox -> mailbox
        end

    {:ok, mailbox} =
      Email.update_mailbox_private_storage(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: wrapped_payload(),
        private_storage_verifier: wrapped_payload()
      })

    mailbox
  end

  defp wrapped_payload do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "scrypt",
      "n" => 16_384,
      "r" => 8,
      "p" => 1,
      "salt" => Base.encode64("1234567890123456"),
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext-payload")
    }
  end

  defp public_key_pem do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}

    :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])
  end

  defp payload_value(payload, string_key, atom_key) do
    Map.get(payload, string_key) || Map.get(payload, atom_key)
  end
end
