defmodule Elektrine.Email.MailboxPrivateStorageTest do
  use Elektrine.DataCase

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.Email.Mailbox
  alias Elektrine.Email.MailboxEncryption
  alias Elektrine.Email.Receiver
  alias Elektrine.Notifications
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
        raw_source:
          "From: sender@example.com\r\nTo: #{mailbox.email}\r\n\r\nPrivate original MIME",
        message_id: "<private-#{System.unique_integer([:positive])}@example.com>",
        metadata: %{
          "body_format" => "markdown",
          "headers" => %{"Subject" => "Launch plans"},
          "attachments" => [%{"data" => "launch details"}],
          "custom_plaintext" => "This should not be stored"
        },
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
    assert stored_message.from == "Encrypted sender"
    assert stored_message.to == "Encrypted recipients"
    assert is_nil(stored_message.text_body)
    assert is_nil(stored_message.html_body)
    assert is_nil(stored_message.raw_source)
    assert is_nil(stored_message.encrypted_raw_source)
    assert stored_message.search_index == []
    assert stored_message.metadata == %{"body_format" => "markdown", "private_storage" => true}
    refute inspect(stored_message.metadata) =~ "Launch plans"
    refute inspect(stored_message.metadata) =~ "launch details"
    refute inspect(stored_message.metadata) =~ "This should not be stored"
    refute inspect(stored_message) =~ "Private original MIME"
    assert payload_value(stored_message.client_encrypted_payload, "ciphertext", :ciphertext)
    assert payload_value(stored_message.client_encrypted_payload, "encrypted_key", :encrypted_key)
    assert stored_attachment["filename"] == "Encrypted attachment"
    assert stored_attachment["content_type"] == "application/octet-stream"
    assert stored_attachment["size"] == 0
    assert is_map(stored_attachment["private_encrypted_payload"])
    assert stored_message.client_encrypted_payload["version"] == 2
    assert stored_message.client_encrypted_payload["aad_context"]["kind"] == "message"
    assert stored_attachment["private_encrypted_payload"]["version"] == 2
    assert stored_attachment["private_encrypted_payload"]["aad_context"]["kind"] == "attachment"

    refute MailboxEncryption.valid_payload?(
             stored_attachment["private_encrypted_payload"],
             :message
           )

    refute Map.has_key?(stored_attachment, "data")

    notification = email_notification_for(user.id, stored_message.id)
    assert notification.title == "New encrypted email"
    assert notification.body == "Unlock your mailbox to view this message."
    refute notification.title =~ "sender@example.com"
    refute notification.body =~ "Launch plans"
  end

  test "incoming private mailbox metadata does not store plaintext headers or attachments" do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, message} =
      Receiver.process_incoming_email(%{
        "from" => "private-sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Private inbound subject",
        "plain_body" => "Private inbound body",
        "html_body" => "<p>Private inbound body</p>",
        "spam_score" => "0.1",
        "message_id" => "private-inbound-#{System.unique_integer([:positive])}@example.com",
        "headers" => %{
          "From" => "private-sender@example.com",
          "To" => mailbox.email,
          "Subject" => "Private inbound subject"
        },
        "attachments" => [
          %{
            "filename" => "secret.txt",
            "content_type" => "text/plain",
            "data" => "sensitive attachment body"
          }
        ]
      })

    stored_message = Repo.get!(Email.Message, message.id)
    stored_attachment = stored_message.attachments["attachment_0"]

    assert stored_message.metadata["private_storage"] == true
    assert stored_message.metadata["spam_score"] == "0.1"
    refute Map.has_key?(stored_message.metadata, "headers")
    refute Map.has_key?(stored_message.metadata, "attachments")
    refute inspect(stored_message.metadata) =~ "Private inbound subject"
    refute inspect(stored_message.metadata) =~ "private-sender@example.com"
    refute inspect(stored_message.metadata) =~ "sensitive attachment body"

    assert stored_message.subject == "Encrypted message"
    assert stored_message.from == "Encrypted sender"
    assert stored_attachment["filename"] == "Encrypted attachment"
    assert is_map(stored_attachment["private_encrypted_payload"])
    refute Map.has_key?(stored_attachment, "data")
  end

  test "oversized raw sources are omitted before private mailbox encryption" do
    previous_email_config = Application.get_env(:elektrine, :email, [])

    Application.put_env(
      :elektrine,
      :email,
      Keyword.put(previous_email_config, :max_retained_raw_source_bytes, 16)
    )

    on_exit(fn -> Application.put_env(:elektrine, :email, previous_email_config) end)

    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Private raw retention",
        text_body: "Display content",
        raw_source: String.duplicate("x", 17),
        message_id: "<private-raw-retention@example.com>"
      })

    stored_message = Repo.get!(Email.Message, message.id)

    assert is_nil(stored_message.encrypted_raw_source)
    assert stored_message.metadata["private_storage"] == true
    assert stored_message.metadata["raw_source_retained"] == false
    assert stored_message.metadata["raw_source_original_bytes"] == 17
    assert stored_message.metadata["raw_source_retention_limit_bytes"] == 16
    assert stored_message.metadata["raw_source_omitted_reason"] == "size_limit"
  end

  test "create_message protects sent-copy metadata for private mailboxes" do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: mailbox.email,
        to: "recipient@example.com",
        cc: "copy@example.com",
        bcc: "blind@example.com",
        subject: "Sent secret",
        text_body: "Sent body should stay private",
        message_id: "<private-sent-#{System.unique_integer([:positive])}@example.com>",
        status: "sent"
      })

    stored_message = Repo.get!(Email.Message, message.id)

    assert stored_message.status == "sent"
    assert stored_message.from == "Encrypted sender"
    assert stored_message.to == "Encrypted recipients"
    assert stored_message.cc == "Encrypted recipients"
    assert stored_message.bcc == "Encrypted recipients"
    assert stored_message.subject == "Encrypted message"
    assert is_nil(stored_message.text_body)
    assert stored_message.search_index == []
    assert payload_value(stored_message.client_encrypted_payload, "ciphertext", :ciphertext)
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

    master_mailbox = %Mailbox{
      private_storage_public_key: public_key_pem(),
      private_storage_wrapped_private_key: master_wrapped_payload("private_key"),
      private_storage_verifier: master_wrapped_payload("verifier")
    }

    assert Mailbox.private_storage_unlock_mode(legacy_mailbox) == "separate_passphrase"
    assert Mailbox.private_storage_unlock_mode(account_password_mailbox) == "account_password"
    assert Mailbox.private_storage_account_password?(account_password_mailbox)
    assert Mailbox.private_storage_unlock_mode(master_mailbox) == "master"
    refute Mailbox.private_storage_account_password?(master_mailbox)
  end

  test "private storage changeset accepts a master-wrapped (key-wrapped) payload" do
    user = AccountsFixtures.user_fixture()

    mailbox =
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end

    changeset =
      Mailbox.private_storage_changeset(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: master_wrapped_payload("private_key"),
        private_storage_verifier: master_wrapped_payload("verifier")
      })

    assert changeset.valid?

    # A master payload that still carries the wrong unlock_mode must be rejected.
    invalid =
      master_wrapped_payload("private_key")
      |> Map.put("unlock_mode", "account_password")

    invalid_changeset =
      Mailbox.private_storage_changeset(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: invalid,
        private_storage_verifier: master_wrapped_payload("verifier")
      })

    refute invalid_changeset.valid?
    assert invalid_changeset.errors[:private_storage_wrapped_private_key]
  end

  test "private storage changeset requires v2 wrapped payload AAD context" do
    user = AccountsFixtures.user_fixture()

    mailbox =
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end

    invalid_v2_payload =
      wrapped_payload()
      |> Map.put("version", 2)
      |> Map.put("unlock_mode", "account_password")

    changeset =
      Mailbox.private_storage_changeset(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: invalid_v2_payload,
        private_storage_verifier: invalid_v2_payload
      })

    refute changeset.valid?
    assert changeset.errors[:private_storage_wrapped_private_key]
  end

  test "private storage changeset binds v2 wrapped payload AAD kind to each field" do
    user = AccountsFixtures.user_fixture()

    mailbox =
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end

    valid_changeset =
      Mailbox.private_storage_changeset(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: v2_wrapped_payload("private_key"),
        private_storage_verifier: v2_wrapped_payload("verifier")
      })

    assert valid_changeset.valid?

    swapped_changeset =
      Mailbox.private_storage_changeset(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: v2_wrapped_payload("verifier"),
        private_storage_verifier: v2_wrapped_payload("private_key")
      })

    refute swapped_changeset.valid?
    assert swapped_changeset.errors[:private_storage_wrapped_private_key]

    swapped_verifier_changeset =
      Mailbox.private_storage_changeset(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: v2_wrapped_payload("private_key"),
        private_storage_verifier: v2_wrapped_payload("private_key")
      })

    refute swapped_verifier_changeset.valid?
    assert swapped_verifier_changeset.errors[:private_storage_verifier]
  end

  test "reset_user_private_storage clears stale mailbox key wrappers" do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    assert Mailbox.private_storage_configured?(mailbox)

    assert {:ok, 1} = Email.reset_user_private_storage(user.id)

    mailbox = Email.get_user_mailbox(user.id)
    refute mailbox.private_storage_enabled
    refute Mailbox.private_storage_configured?(mailbox)
    assert is_nil(mailbox.private_storage_public_key)
    assert is_nil(mailbox.private_storage_wrapped_private_key)
    assert is_nil(mailbox.private_storage_verifier)
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

  defp email_notification_for(user_id, message_id) do
    user_id
    |> Notifications.list_notifications(limit: 20)
    |> Enum.find(&(&1.type == "email_received" and &1.source_id == message_id))
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

  defp v2_wrapped_payload(kind) do
    wrapped_payload()
    |> Map.put("version", 2)
    |> Map.put("unlock_mode", "account_password")
    |> Map.put("aad_context", %{
      "purpose" => "elektrine-private-mailbox-key-wrap",
      "version" => 2,
      "kind" => kind,
      "algorithm" => "AES-GCM",
      "kdf" => "scrypt",
      "unlock_mode" => "account_password"
    })
  end

  defp master_wrapped_payload(kind) do
    %{
      "version" => 2,
      "algorithm" => "AES-GCM",
      "kdf" => "master",
      "unlock_mode" => "master",
      "aad_context" => %{
        "purpose" => "elektrine-private-mailbox-key-wrap",
        "version" => 2,
        "kind" => kind,
        "algorithm" => "AES-GCM",
        "kdf" => "master",
        "unlock_mode" => "master"
      },
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
