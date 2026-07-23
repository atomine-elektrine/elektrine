defmodule Elektrine.EmailBasicFunctionsTest do
  @moduledoc """
  Tests for basic email functionality without external dependencies like Haraka.
  Focuses on core email operations: creation, storage, retrieval, and management.
  """

  use Elektrine.DataCase
  alias Elektrine.Accounts
  alias Elektrine.Domains
  alias Elektrine.Email
  alias Elektrine.Notifications

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
      assert mailbox.email == "#{user.username}@#{Domains.primary_email_domain()}"

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
      assert Email.get_mailbox_by_email("nonexistent@example.net") == nil
    end

    test "verify_email_ownership accepts routable mailbox variants", %{user: user} do
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      assert {:ok, :main_mailbox} = Email.verify_email_ownership(mailbox.email, user.id)

      assert {:ok, :main_mailbox} =
               Email.verify_email_ownership(
                 "#{user.username}+tag@#{Domains.primary_email_domain()}",
                 user.id
               )

      alternate_domain =
        Elektrine.Domains.supported_email_domains()
        |> Enum.reject(&(&1 == Elektrine.Domains.primary_email_domain()))
        |> List.first()

      if alternate_domain do
        assert {:ok, :main_mailbox} =
                 Email.verify_email_ownership("#{user.username}@#{alternate_domain}", user.id)
      end
    end

    test "verify_email_ownership rejects secondary example.org addresses for sending", %{
      user: user
    } do
      previous_email_config = Application.get_env(:elektrine, :email, [])
      primary = Domains.primary_email_domain()

      Application.put_env(
        :elektrine,
        :email,
        Keyword.merge(previous_email_config, supported_domains: [primary, "example.org"])
      )

      on_exit(fn -> Application.put_env(:elektrine, :email, previous_email_config) end)

      {:ok, _mailbox} = Email.ensure_user_has_mailbox(user)

      assert {:error, :receive_only_domain} =
               Email.verify_email_ownership("#{user.username}@example.org", user.id)
    end

    test "get_user_mailbox prefers the canonical mailbox when legacy duplicates exist", %{
      user: user
    } do
      {:ok, canonical_mailbox} = Email.ensure_user_has_mailbox(user)

      {:ok, _legacy_mailbox} =
        Email.create_mailbox(%{email: "#{user.username}@example.net", user_id: user.id})

      retrieved = Email.get_user_mailbox(user.id)
      assert retrieved.id == canonical_mailbox.id
      assert retrieved.username == user.username
    end

    test "ensure_user_has_mailbox returns the canonical mailbox when legacy duplicates exist", %{
      user: user
    } do
      {:ok, canonical_mailbox} = Email.ensure_user_has_mailbox(user)

      {:ok, _legacy_mailbox} =
        Email.create_mailbox(%{email: "#{user.username}@example.net", user_id: user.id})

      assert {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      assert mailbox.id == canonical_mailbox.id
      assert mailbox.username == user.username
    end

    test "update_mailbox_email keeps username in sync for cross-domain lookup", %{user: user} do
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      new_email = "renamed@#{Domains.primary_email_domain()}"

      alternate_domain =
        Elektrine.Domains.supported_email_domains()
        |> Enum.reject(&(&1 == Elektrine.Domains.primary_email_domain()))
        |> List.first()

      assert {:ok, updated_mailbox} = Email.update_mailbox_email(mailbox, new_email)
      assert updated_mailbox.email == new_email
      assert updated_mailbox.username == "renamed"

      if alternate_domain do
        resolved_mailbox = Email.get_mailbox_by_email("renamed@#{alternate_domain}")
        assert resolved_mailbox.id == updated_mailbox.id
        assert resolved_mailbox.user_id == user.id
      end
    end

    test "transition_mailbox_for_username_change preserves mailbox data", %{user: user} do
      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      {:ok, message} =
        Email.create_message(%{
          message_id: "rename-preserves-message",
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Keep me",
          text_body: "This message should remain in the mailbox.",
          status: "received",
          mailbox_id: mailbox.id
        })

      renamed_user = %{user | username: "renamed"}
      new_email = "renamed@#{Domains.primary_email_domain()}"

      alternate_domain =
        Elektrine.Domains.supported_email_domains()
        |> Enum.reject(&(&1 == Elektrine.Domains.primary_email_domain()))
        |> List.first()

      assert {:ok, updated_mailbox} =
               Email.transition_mailbox_for_username_change(renamed_user, mailbox, new_email)

      assert updated_mailbox.id == mailbox.id
      assert updated_mailbox.email == new_email
      assert updated_mailbox.username == "renamed"

      if alternate_domain do
        assert Email.get_mailbox_by_email("renamed@#{alternate_domain}").id == updated_mailbox.id
      end

      assert Email.Mailboxes.get_mailbox_internal(mailbox.id).user_id == user.id
      assert Email.get_message_internal(message.id).mailbox_id == mailbox.id
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

  describe "email notification suppression" do
    setup do
      username = "notifself#{System.unique_integer([:positive])}"

      {:ok, user} =
        Accounts.create_user(%{
          username: username,
          password: "NotifSelf123!",
          password_confirmation: "NotifSelf123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

      alias_email = "#{username}alias@#{Domains.primary_email_domain()}"

      {:ok, _alias} =
        Email.create_alias(%{
          alias_email: alias_email,
          target_email: mailbox.email,
          user_id: user.id
        })

      %{user: user, mailbox: mailbox, alias_email: alias_email}
    end

    test "does not create notifications for received mail sent from an address owned by the mailbox user",
         %{
           user: user,
           mailbox: mailbox,
           alias_email: alias_email
         } do
      assert {:ok, _message} =
               Email.create_message(%{
                 message_id: "owned-sender-#{System.unique_integer([:positive])}",
                 from: alias_email,
                 to: mailbox.email,
                 subject: "Owned sender copy",
                 text_body: "hello",
                 status: "received",
                 mailbox_id: mailbox.id,
                 read: false,
                 spam: false,
                 archived: false
               })

      assert Notifications.list_notifications(user.id) == []
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
        DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

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
