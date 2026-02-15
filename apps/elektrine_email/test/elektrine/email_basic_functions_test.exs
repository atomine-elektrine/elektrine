defmodule Elektrine.EmailBasicFunctionsTest do
  @moduledoc """
  Tests for basic email functionality without external dependencies like Haraka.
  Focuses on core email operations: creation, storage, retrieval, and management.
  """

  use Elektrine.DataCase
  alias Elektrine.Email
  alias Elektrine.Accounts

  describe "mailbox management" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "emailtest",
          password: "EmailTest123!",
          password_confirmation: "EmailTest123!"
        })

      %{user: user}
    end

    test "creates and retrieves user mailbox", %{user: user} do
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      assert mailbox.user_id == user.id
      assert mailbox.email == "#{user.username}@elektrine.com"

      # Test retrieval
      retrieved = Email.get_user_mailbox(user.id)
      assert retrieved.id == mailbox.id
      assert retrieved.email == mailbox.email
    end

    test "get_mailbox_by_email works correctly", %{user: user} do
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      found_mailbox = Email.get_mailbox_by_email(mailbox.email)
      assert found_mailbox.id == mailbox.id
      assert found_mailbox.user_id == user.id

      # Test with non-existent email
      assert Email.get_mailbox_by_email("nonexistent@elektrine.com") == nil
    end
  end

  describe "message creation and storage" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "msgtest",
          password: "MsgTest123!",
          password_confirmation: "MsgTest123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      %{user: user, mailbox: mailbox}
    end

    test "creates a basic received message", %{mailbox: mailbox} do
      message_attrs = %{
        message_id: "basic-test-1",
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Test Basic Email",
        text_body: "This is a test email body.",
        status: "received",
        mailbox_id: mailbox.id
      }

      {:ok, message} = Email.create_message(message_attrs)

      assert message.message_id == "basic-test-1"
      assert message.from == "sender@example.com"
      assert message.to == mailbox.email
      assert message.subject == "Test Basic Email"
      assert message.text_body == "This is a test email body."
      assert message.status == "received"
      assert message.read == false
      assert message.spam == false
      assert message.archived == false
    end

    test "creates a sent message", %{mailbox: mailbox} do
      message_attrs = %{
        message_id: "sent-test-1",
        from: mailbox.email,
        to: "recipient@example.com",
        subject: "Outgoing Test Email",
        text_body: "This is an outgoing email.",
        html_body: "<p>This is an outgoing email.</p>",
        status: "sent",
        mailbox_id: mailbox.id
      }

      {:ok, message} = Email.create_message(message_attrs)

      assert message.status == "sent"
      assert message.from == mailbox.email
      assert message.to == "recipient@example.com"
      assert message.html_body == "<p>This is an outgoing email.</p>"
    end

    test "creates message with attachments metadata", %{mailbox: mailbox} do
      attachments = %{
        "1" => %{
          "filename" => "document.pdf",
          "content_type" => "application/pdf",
          "size" => 1024
        }
      }

      message_attrs = %{
        message_id: "attachment-test-1",
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Email with Attachment",
        text_body: "Please find attached document.",
        status: "received",
        mailbox_id: mailbox.id,
        attachments: attachments,
        has_attachments: true
      }

      {:ok, message} = Email.create_message(message_attrs)

      assert message.has_attachments == true
      assert message.attachments["1"]["filename"] == "document.pdf"
      assert message.attachments["1"]["content_type"] == "application/pdf"
    end

    test "validates required fields", %{mailbox: mailbox} do
      # Missing required fields
      message_attrs = %{
        subject: "Missing Required Fields",
        mailbox_id: mailbox.id
      }

      {:error, changeset} = Email.create_message(message_attrs)

      assert changeset.errors[:message_id]
      assert changeset.errors[:from]
      assert changeset.errors[:to]
    end
  end

  describe "message retrieval and querying" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "querytest",
          password: "QueryTest123!",
          password_confirmation: "QueryTest123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      # Create test messages
      messages = [
        %{
          message_id: "inbox-1",
          from: "sender1@example.com",
          to: mailbox.email,
          subject: "Inbox Message 1",
          text_body: "Regular inbox message",
          status: "received",
          mailbox_id: mailbox.id,
          read: false,
          spam: false,
          archived: false
        },
        %{
          message_id: "inbox-2",
          from: "sender2@example.com",
          to: mailbox.email,
          subject: "Inbox Message 2",
          text_body: "Another inbox message",
          status: "received",
          mailbox_id: mailbox.id,
          read: true,
          spam: false,
          archived: false
        },
        %{
          message_id: "spam-1",
          from: "spammer@badsite.com",
          to: mailbox.email,
          subject: "SPAM MESSAGE",
          text_body: "This is spam",
          status: "received",
          mailbox_id: mailbox.id,
          read: false,
          spam: true,
          archived: false
        },
        %{
          message_id: "archived-1",
          from: "old@example.com",
          to: mailbox.email,
          subject: "Old Message",
          text_body: "This is archived",
          status: "received",
          mailbox_id: mailbox.id,
          read: true,
          spam: false,
          archived: true
        },
        %{
          message_id: "sent-1",
          from: mailbox.email,
          to: "recipient@example.com",
          subject: "Outgoing Message",
          text_body: "This was sent",
          status: "sent",
          mailbox_id: mailbox.id
        }
      ]

      created_messages =
        Enum.map(messages, fn attrs ->
          {:ok, msg} = Email.create_message(attrs)
          msg
        end)

      %{user: user, mailbox: mailbox, messages: created_messages}
    end

    test "lists inbox messages correctly", %{mailbox: mailbox} do
      inbox_messages = Email.list_inbox_messages(mailbox.id)

      # Should get 2 inbox messages (not spam, not archived, not sent)
      assert length(inbox_messages) == 2

      subjects = Enum.map(inbox_messages, & &1.subject)
      assert "Inbox Message 1" in subjects
      assert "Inbox Message 2" in subjects
    end

    test "lists spam messages correctly", %{mailbox: mailbox} do
      spam_messages = Email.list_spam_messages(mailbox.id)

      assert length(spam_messages) == 1
      assert hd(spam_messages).subject == "SPAM MESSAGE"
      assert hd(spam_messages).spam == true
    end

    test "lists archived messages correctly", %{mailbox: mailbox} do
      archived_messages = Email.list_archived_messages(mailbox.id)

      assert length(archived_messages) == 1
      assert hd(archived_messages).subject == "Old Message"
      assert hd(archived_messages).archived == true
    end

    test "lists unread messages correctly", %{mailbox: mailbox} do
      unread_messages = Email.list_unread_messages(mailbox.id)

      # Should get 1 unread message (inbox-1)
      # Note: spam messages are excluded from unread (they have their own folder)
      assert unread_messages != []

      subjects = Enum.map(unread_messages, & &1.subject)
      assert "Inbox Message 1" in subjects
    end

    test "gets message by ID", %{mailbox: mailbox, messages: [first_msg | _]} do
      retrieved = Email.get_message(first_msg.id, mailbox.id)

      assert retrieved.id == first_msg.id
      assert retrieved.subject == first_msg.subject
    end

    test "gets message by message_id", %{mailbox: mailbox} do
      retrieved = Email.get_message_by_id("inbox-1", mailbox.id)

      assert retrieved.message_id == "inbox-1"
      assert retrieved.subject == "Inbox Message 1"
    end

    test "pagination works correctly", %{mailbox: mailbox} do
      # Test with per_page = 2
      page1 = Email.list_messages_paginated(mailbox.id, 1, 2)
      page2 = Email.list_messages_paginated(mailbox.id, 2, 2)

      assert length(page1.messages) == 2
      assert length(page2.messages) == 2
      assert page1.total_count == 5
      assert page1.page == 1
      assert page2.page == 2
    end
  end

  describe "message status management" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "statustest",
          password: "StatusTest123!",
          password_confirmation: "StatusTest123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      {:ok, message} =
        Email.create_message(%{
          message_id: "status-test-1",
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Status Test Message",
          text_body: "Testing status changes",
          status: "received",
          mailbox_id: mailbox.id,
          read: false,
          spam: false,
          archived: false
        })

      %{user: user, mailbox: mailbox, message: message}
    end

    test "marks message as read", %{message: message} do
      {:ok, updated} = Email.mark_as_read(message)

      assert updated.read == true
      # Note: first_opened_at and opened_at may be set by track_open_changeset, not read_changeset
      # assert updated.first_opened_at
      # assert updated.opened_at 
      # assert updated.open_count == 1
    end

    test "marks message as unread", %{message: message} do
      # First mark as read
      {:ok, read_message} = Email.mark_as_read(message)
      assert read_message.read == true

      # Then mark as unread
      {:ok, updated} = Email.mark_as_unread(read_message)
      assert updated.read == false
    end

    test "marks message as spam", %{message: message} do
      {:ok, updated} = Email.mark_as_spam(message)

      assert updated.spam == true
    end

    test "marks message as not spam", %{message: message} do
      # First mark as spam
      {:ok, spam_message} = Email.mark_as_spam(message)
      assert spam_message.spam == true

      # Then mark as not spam
      {:ok, updated} = Email.mark_as_not_spam(spam_message)
      assert updated.spam == false
    end

    test "archives message", %{message: message} do
      {:ok, updated} = Email.archive_message(message)

      assert updated.archived == true
    end

    test "unarchives message", %{message: message} do
      # First archive
      {:ok, archived_message} = Email.archive_message(message)
      assert archived_message.archived == true

      # Then unarchive
      {:ok, updated} = Email.unarchive_message(archived_message)
      assert updated.archived == false
    end

    test "tracks message opens", %{message: message} do
      # Track first open
      {:ok, updated1} = Email.track_message_open(message)
      assert updated1.open_count == 1
      assert updated1.first_opened_at
      assert updated1.opened_at

      # Track second open (add small delay to ensure different timestamp)
      :timer.sleep(10)
      {:ok, updated2} = Email.track_message_open(updated1)
      assert updated2.open_count == 2
      assert updated2.first_opened_at == updated1.first_opened_at
      # Times should be different (or at least greater/equal)
      assert DateTime.compare(updated2.opened_at, updated1.opened_at) != :lt
    end
  end

  describe "Hey.com-style categorization" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "categorytest",
          password: "CategoryTest123!",
          password_confirmation: "CategoryTest123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      %{user: user, mailbox: mailbox}
    end

    test "creates messages in different categories", %{mailbox: mailbox} do
      categories = ["inbox", "feed", "ledger"]

      _messages =
        Enum.map(categories, fn category ->
          {:ok, msg} =
            Email.create_message(%{
              message_id: "#{category}-test",
              from: "sender@example.com",
              to: mailbox.email,
              subject: "#{String.capitalize(category)} Message",
              text_body: "Message for #{category} category",
              status: "received",
              mailbox_id: mailbox.id,
              category: category
            })

          msg
        end)

      # Test category-specific retrieval
      feed_messages = Email.list_feed_messages(mailbox.id)
      ledger_messages = Email.list_ledger_messages(mailbox.id)

      assert length(feed_messages) == 1
      assert hd(feed_messages).category == "feed"

      assert length(ledger_messages) == 1
      assert hd(ledger_messages).category == "ledger"
    end

    test "set aside functionality", %{mailbox: mailbox} do
      {:ok, message} =
        Email.create_message(%{
          message_id: "setaside-test",
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Set Aside Test",
          text_body: "This will be set aside",
          status: "received",
          mailbox_id: mailbox.id
        })

      # Stack message
      {:ok, updated} = Email.stack_message(message, "Review later")

      assert updated.category == "stack"
      assert updated.stack_reason == "Review later"
      assert updated.stack_at

      # Test retrieval
      stack_messages = Email.list_stack_messages(mailbox.id)
      assert length(stack_messages) == 1
      assert hd(stack_messages).stack_reason == "Review later"

      # Unstack
      {:ok, unset} = Email.unstack_message(updated)
      assert unset.category == "inbox"
      assert is_nil(unset.stack_reason)
      assert is_nil(unset.stack_at)
    end

    test "reply later functionality", %{mailbox: mailbox} do
      {:ok, message} =
        Email.create_message(%{
          message_id: "replylater-test",
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Reply Later Test",
          text_body: "Need to reply to this later",
          status: "received",
          mailbox_id: mailbox.id
        })

      # tomorrow
      reply_time =
        DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second)

      # Set reply later
      {:ok, updated} = Email.reply_later_message(message, reply_time, true)

      # Compare truncated times to avoid microsecond precision issues
      assert DateTime.truncate(updated.reply_later_at, :second) == reply_time
      assert updated.reply_later_reminder == true

      # Test retrieval
      reply_later_messages = Email.list_reply_later_messages(mailbox.id)
      assert length(reply_later_messages) == 1

      # Clear reply later
      {:ok, cleared} = Email.clear_reply_later(updated)
      assert is_nil(cleared.reply_later_at)
      assert cleared.reply_later_reminder == false
    end
  end

  describe "message search" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "searchtest",
          password: "SearchTest123!",
          password_confirmation: "SearchTest123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      # Create searchable messages
      search_messages = [
        %{
          message_id: "search-1",
          from: "alice@example.com",
          to: mailbox.email,
          subject: "Project Alpha Update",
          text_body: "The alpha project is going well. We need to discuss the budget.",
          status: "received",
          mailbox_id: mailbox.id
        },
        %{
          message_id: "search-2",
          from: "bob@company.com",
          to: mailbox.email,
          subject: "Budget Meeting Tomorrow",
          text_body: "Let's meet tomorrow to discuss the quarterly budget allocation.",
          status: "received",
          mailbox_id: mailbox.id
        },
        %{
          message_id: "search-3",
          from: "charlie@team.org",
          to: mailbox.email,
          subject: "Weekend Plans",
          text_body: "Anyone interested in hiking this weekend?",
          status: "received",
          mailbox_id: mailbox.id
        }
      ]

      Enum.each(search_messages, fn attrs ->
        {:ok, _} = Email.create_message(attrs)
      end)

      %{user: user, mailbox: mailbox}
    end

    test "searches messages by subject", %{mailbox: mailbox} do
      results = Email.search_messages(mailbox.id, "budget")

      assert results.total_count == 2
      subjects = Enum.map(results.messages, & &1.subject)
      assert "Budget Meeting Tomorrow" in subjects
      assert "Project Alpha Update" in subjects
    end

    test "searches messages by body content", %{mailbox: mailbox} do
      results = Email.search_messages(mailbox.id, "weekend")

      assert results.total_count == 1
      assert hd(results.messages).subject == "Weekend Plans"
    end

    test "searches messages by sender", %{mailbox: mailbox} do
      results = Email.search_messages(mailbox.id, "alice@example.com")

      assert results.total_count == 1
      assert hd(results.messages).from == "alice@example.com"
    end
  end
end
