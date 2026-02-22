defmodule Elektrine.EmailEncryptionTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.{Accounts, Email, Repo}
  alias Elektrine.Email.Message

  setup do
    # Create test user with unique username
    username = "testuser#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.create_user(%{
        username: username,
        password: "password123456",
        password_confirmation: "password123456"
      })

    # Get or create mailbox (user creation may have already created one)
    mailbox =
      case Email.get_user_mailbox(user.id) do
        nil ->
          {:ok, mailbox} = Email.create_mailbox(user)
          mailbox

        existing_mailbox ->
          existing_mailbox
      end

    %{user: user, mailbox: mailbox}
  end

  describe "email encryption on creation" do
    test "encrypts text_body when creating email", %{mailbox: mailbox} do
      text_body = "This is a secret email message"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Test Email",
          text_body: text_body,
          status: "received"
        })

      # Reload from database
      db_message = Repo.get(Message, message.id)

      # Text body should be encrypted
      assert db_message.encrypted_text_body != nil
      assert is_map(db_message.encrypted_text_body)
      assert Map.has_key?(db_message.encrypted_text_body, "encrypted_data")

      # Search index should be created
      assert is_list(db_message.search_index)
      assert db_message.search_index != []

      # Plaintext should NOT be stored in database
      assert db_message.text_body == nil
    end

    test "encrypts html_body when creating email", %{mailbox: mailbox} do
      html_body = "<html><body><p>Secret HTML content</p></body></html>"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test2@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "HTML Email",
          html_body: html_body,
          status: "received"
        })

      db_message = Repo.get(Message, message.id)

      # HTML body should be encrypted
      assert db_message.encrypted_html_body != nil
      assert is_map(db_message.encrypted_html_body)

      # Search index should be created from HTML
      assert db_message.search_index != []

      # Plaintext should NOT be stored in database
      assert db_message.html_body == nil
    end

    test "encrypts both text and html bodies", %{mailbox: mailbox} do
      text_body = "Plain text version"
      html_body = "<html><body>HTML version</body></html>"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test3@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Multipart Email",
          text_body: text_body,
          html_body: html_body,
          status: "received"
        })

      db_message = Repo.get(Message, message.id)

      # Both should be encrypted
      assert db_message.encrypted_text_body != nil
      assert db_message.encrypted_html_body != nil

      # Search index should prioritize text_body
      assert db_message.search_index != []

      # Plaintext should NOT be stored in database
      assert db_message.text_body == nil
      assert db_message.html_body == nil
    end

    test "creates searchable index with keywords from email body", %{mailbox: mailbox, user: user} do
      text_body = "Meeting scheduled for #project deadline tomorrow"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test4@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Project Meeting",
          text_body: text_body,
          status: "received"
        })

      db_message = Repo.get(Message, message.id)

      # Verify keywords are in search index
      meeting_hash = Elektrine.Encryption.hash_keyword("meeting", user.id)
      project_hash = Elektrine.Encryption.hash_keyword("#project", user.id)
      deadline_hash = Elektrine.Encryption.hash_keyword("deadline", user.id)

      assert meeting_hash in db_message.search_index
      assert project_hash in db_message.search_index
      assert deadline_hash in db_message.search_index
    end

    test "handles empty body gracefully", %{mailbox: mailbox} do
      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test5@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "No Body",
          status: "received"
        })

      # Should not crash, encrypted fields should be nil
      assert message.encrypted_text_body == nil
      assert message.encrypted_html_body == nil
    end
  end

  describe "email decryption on retrieval" do
    test "decrypts email when retrieved by ID", %{mailbox: mailbox} do
      text_body = "Secret email content"

      {:ok, created_message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test6@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Test",
          text_body: text_body,
          status: "received"
        })

      # Get message by ID
      retrieved_message = Email.get_message(created_message.id, mailbox.id)

      # Should be decrypted
      assert retrieved_message.text_body == text_body
    end

    test "decrypts email when retrieved by hash", %{mailbox: mailbox} do
      text_body = "Another secret message"

      {:ok, created_message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test7@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Test",
          text_body: text_body,
          status: "received"
        })

      # Get message by hash
      retrieved_message = Email.get_message_by_hash(created_message.hash)

      # Should be decrypted
      assert retrieved_message.text_body == text_body
    end

    test "decrypts inbox messages list", %{mailbox: mailbox} do
      text_body = "Inbox message content"

      {:ok, _message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test8@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Inbox Test",
          text_body: text_body,
          status: "received"
        })

      # List inbox messages
      messages = Email.list_inbox_messages(mailbox.id, 10, 0)

      # Should find and decrypt the message
      assert Enum.any?(messages, fn m -> m.text_body == text_body end)
    end

    test "decrypts both text and html bodies", %{mailbox: mailbox} do
      text_body = "Plain text"
      html_body = "<html><body>HTML body</body></html>"

      {:ok, created_message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<test9@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Multipart",
          text_body: text_body,
          html_body: html_body,
          status: "received"
        })

      retrieved_message = Email.get_message(created_message.id, mailbox.id)

      # Both should be decrypted
      assert retrieved_message.text_body == text_body
      assert retrieved_message.html_body == html_body
    end
  end

  describe "POP3 message decryption" do
    test "decrypts messages for POP3 access", %{mailbox: mailbox} do
      text_body = "POP3 test message"

      {:ok, _message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<pop3test@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "POP3 Test",
          text_body: text_body,
          status: "received"
        })

      # Get messages for POP3
      pop3_messages = Email.list_messages_for_pop3(mailbox.id)

      # Should be decrypted
      assert Enum.any?(pop3_messages, fn m -> m.text_body == text_body end)
    end

    test "POP3 messages include all required fields", %{mailbox: mailbox} do
      {:ok, _message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<pop3test2@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "POP3 Test",
          text_body: "Test content",
          status: "received"
        })

      pop3_messages = Email.list_messages_for_pop3(mailbox.id)

      assert pop3_messages != []
      message = hd(pop3_messages)

      # Verify structure
      assert Map.has_key?(message, :id)
      assert Map.has_key?(message, :message_id)
      assert Map.has_key?(message, :from)
      assert Map.has_key?(message, :to)
      assert Map.has_key?(message, :subject)
      assert Map.has_key?(message, :text_body)
      assert Map.has_key?(message, :html_body)
    end
  end

  describe "IMAP message decryption" do
    test "decrypts messages when fetched via IMAP", %{mailbox: mailbox} do
      text_body = "IMAP test message"

      {:ok, created_message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<imaptest@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "IMAP Test",
          text_body: text_body,
          status: "received"
        })

      # IMAP fetches individual messages by ID
      fetched_message = Email.get_message(created_message.id, mailbox.id)

      # Should be decrypted
      assert fetched_message.text_body == text_body
    end

    test "IMAP folder listing works with encrypted messages", %{mailbox: mailbox} do
      {:ok, _msg1} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<imap1@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Inbox Message",
          text_body: "Inbox content",
          status: "received"
        })

      {:ok, _msg2} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<imap2@example.com>",
          from: "test@example.com",
          to: "recipient@example.com",
          subject: "Sent Message",
          text_body: "Sent content",
          status: "sent"
        })

      # List messages for inbox folder
      inbox_messages = Email.list_messages_for_imap(mailbox.id, :inbox)
      assert inbox_messages != []

      # List messages for sent folder
      sent_messages = Email.list_messages_for_imap(mailbox.id, :sent)
      assert sent_messages != []
    end
  end

  describe "encryption with special content" do
    test "encrypts unicode and emoji in email", %{mailbox: mailbox} do
      text_body = "Hello 世界 🌍 Special characters: é, ñ, ü"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<unicode@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Unicode Test",
          text_body: text_body,
          status: "received"
        })

      retrieved = Email.get_message(message.id, mailbox.id)
      assert retrieved.text_body == text_body
    end

    test "encrypts long email bodies", %{mailbox: mailbox} do
      text_body = String.duplicate("Long email content. ", 500)

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<long@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Long Email",
          text_body: text_body,
          status: "received"
        })

      retrieved = Email.get_message(message.id, mailbox.id)
      assert retrieved.text_body == text_body
    end

    test "handles HTML with special characters", %{mailbox: mailbox} do
      html_body = "<html><body><p>Price: €100 • Product™</p></body></html>"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<html@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "HTML Test",
          html_body: html_body,
          status: "received"
        })

      retrieved = Email.get_message(message.id, mailbox.id)
      assert retrieved.html_body == html_body
    end
  end

  describe "sent email encryption" do
    test "encrypts sent emails", %{mailbox: mailbox} do
      text_body = "Outgoing secret message"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<sent@example.com>",
          from: "test@example.com",
          to: "recipient@example.com",
          subject: "Sent Email",
          text_body: text_body,
          status: "sent"
        })

      db_message = Repo.get(Message, message.id)

      # Should be encrypted
      assert db_message.encrypted_text_body != nil
      assert db_message.search_index != []
    end
  end

  describe "message updates with encryption" do
    test "maintains encryption when updating flags", %{mailbox: mailbox} do
      text_body = "Original content"

      {:ok, message} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          message_id: "<update@example.com>",
          from: "sender@example.com",
          to: "test@example.com",
          subject: "Update Test",
          text_body: text_body,
          status: "received"
        })

      # Update message flags
      {:ok, _updated} = Email.update_message_flags(message.id, %{read: true})

      # Content should still be encrypted
      db_message = Repo.get(Message, message.id)
      assert db_message.encrypted_text_body != nil

      # But should decrypt properly when retrieved
      retrieved = Email.get_message(message.id, mailbox.id)
      assert retrieved.text_body == text_body
      assert retrieved.read == true
    end
  end
end
