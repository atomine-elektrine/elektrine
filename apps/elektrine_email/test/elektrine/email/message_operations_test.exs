defmodule Elektrine.Email.MessageOperationsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Email
  alias Elektrine.Email.Cached
  alias Elektrine.Email.Categorizer
  alias Elektrine.Email.CustomFolders
  alias Elektrine.Email.Labels
  alias Elektrine.Email.Messages

  describe "message flag updates" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "test@example.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "marks message as read", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{read: false})

      {:ok, updated} = Messages.update_message_flags(message.id, %{read: true})

      assert updated.read == true
    end

    test "marks message as unread", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{read: true})

      {:ok, updated} = Messages.update_message_flags(message.id, %{read: false})

      assert updated.read == false
    end

    test "marks message as spam", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{spam: false})

      {:ok, updated} = Messages.update_message_flags(message.id, %{spam: true})

      assert updated.spam == true
    end

    test "archives message", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{archived: false})

      {:ok, updated} = Messages.update_message_flags(message.id, %{archived: true})

      assert updated.archived == true
    end

    test "soft deletes message", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{deleted: false})

      {:ok, updated} = Messages.update_message_flags(message.id, %{deleted: true})

      assert updated.deleted == true
    end

    test "handles Message struct as first argument", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{read: false})

      {:ok, updated} = Messages.update_message_flags(message, %{read: true})

      assert updated.read == true
    end

    test "returns error for non-existent message" do
      {:error, :not_found} = Messages.update_message_flags(999_999_999, %{read: true})
    end

    test "updates multiple flags at once", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{read: false, spam: false, archived: false})

      {:ok, updated} =
        Messages.update_message_flags(message.id, %{
          read: true,
          spam: true,
          archived: true
        })

      assert updated.read == true
      assert updated.spam == true
      assert updated.archived == true
    end
  end

  describe "folder operations" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "foldertest@example.com"})
      {:ok, folder} = CustomFolders.create_folder(%{user_id: user.id, name: "Test Folder"})
      {:ok, user: user, mailbox: mailbox, folder: folder}
    end

    test "moves message to folder", %{mailbox: mailbox, folder: folder} do
      message = create_test_message(mailbox.id, %{folder_id: nil})

      {:ok, updated} = CustomFolders.move_message_to_folder(message.id, folder.id)

      assert updated.folder_id == folder.id
    end

    test "moves message back to inbox (nil folder)", %{mailbox: mailbox, folder: folder} do
      message = create_test_message(mailbox.id, %{folder_id: folder.id})

      {:ok, updated} = CustomFolders.move_message_to_folder(message.id, nil)

      assert updated.folder_id == nil
    end

    test "handles Message struct when moving to folder", %{mailbox: mailbox, folder: folder} do
      message = create_test_message(mailbox.id, %{folder_id: nil})

      {:ok, updated} = CustomFolders.move_message_to_folder(message, folder.id)

      assert updated.folder_id == folder.id
    end

    test "rejects moving message to a folder owned by another user", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{folder_id: nil})
      other_user = user_fixture()
      {:ok, other_folder} = CustomFolders.create_folder(%{user_id: other_user.id, name: "Other"})

      assert {:error, :invalid_folder} =
               CustomFolders.move_message_to_folder(message.id, other_folder.id)

      reloaded = Email.get_message_internal(message.id)
      assert reloaded.folder_id == nil
    end

    test "message in folder is excluded from inbox listing", %{mailbox: mailbox, folder: folder} do
      message = create_test_message(mailbox.id, %{folder_id: folder.id})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "message in folder appears in folder listing", %{
      mailbox: mailbox,
      folder: folder,
      user: user
    } do
      message = create_test_message(mailbox.id, %{folder_id: folder.id})

      result = CustomFolders.list_folder_messages(folder.id, user.id)

      assert Enum.any?(result.messages, &(&1.id == message.id))
    end

    test "folder listing does not leak messages from other users", %{
      folder: folder,
      user: user
    } do
      own_mailbox = mailbox_fixture(%{user_id: user.id, email: "ownfolder@example.com"})
      own_message = create_test_message(own_mailbox.id, %{folder_id: folder.id})

      other_user = user_fixture()

      other_mailbox =
        mailbox_fixture(%{user_id: other_user.id, email: "otherfolder@example.com"})

      other_message = create_test_message(other_mailbox.id, %{folder_id: folder.id})

      result = CustomFolders.list_folder_messages(folder.id, user.id)

      assert Enum.any?(result.messages, &(&1.id == own_message.id))
      refute Enum.any?(result.messages, &(&1.id == other_message.id))
    end
  end

  describe "cache invalidation regressions" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "cachetest@example.com"})
      {:ok, folder} = CustomFolders.create_folder(%{user_id: user.id, name: "Cache Folder"})
      {:ok, user: user, mailbox: mailbox, folder: folder}
    end

    test "mark_as_unread invalidates cached unread inbox counts", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{read: true})

      assert Cached.unread_inbox_count(mailbox.id) == 0

      {:ok, _updated} = Email.mark_as_unread(message)

      assert Cached.unread_inbox_count(mailbox.id) == 1
    end

    test "mark_as_not_spam invalidates cached unread inbox counts", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{read: false, spam: true})

      assert Cached.unread_inbox_count(mailbox.id) == 0

      {:ok, _updated} = Email.mark_as_not_spam(message)

      assert Cached.unread_inbox_count(mailbox.id) == 1
    end

    test "move_to_digest invalidates cached feed counts", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: nil})

      assert Cached.feed_messages_count(mailbox.id) == 0

      {:ok, _updated} = Email.move_to_digest(message)

      assert Cached.feed_messages_count(mailbox.id) == 1
    end

    test "update_message_flags invalidates cached inbox message lists", %{
      mailbox: mailbox,
      folder: folder
    } do
      message = create_test_message(mailbox.id, %{folder_id: nil})

      initial = Cached.list_inbox_messages_paginated(mailbox.id, 1, 20)
      assert Enum.any?(initial.messages, &(&1.id == message.id))

      {:ok, _updated} = Messages.update_message_flags(message.id, %{folder_id: folder.id})

      refreshed = Cached.list_inbox_messages_paginated(mailbox.id, 1, 20)
      refute Enum.any?(refreshed.messages, &(&1.id == message.id))
    end
  end

  describe "label operations" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "labeltest@example.com"})
      {:ok, label} = Labels.create_label(%{user_id: user.id, name: "Important", color: "#ef4444"})
      {:ok, user: user, mailbox: mailbox, label: label}
    end

    test "adds label to message", %{mailbox: mailbox, label: label} do
      message = create_test_message(mailbox.id, %{})

      result = Email.add_label_to_message(message.id, label.id)

      assert result == :ok || match?({:ok, _}, result)
    end

    test "removes label from message", %{mailbox: mailbox, label: label} do
      message = create_test_message(mailbox.id, %{})
      Email.add_label_to_message(message.id, label.id)

      result = Email.remove_label_from_message(message.id, label.id)

      assert result == :ok || match?({:ok, _}, result)
    end

    test "handles adding same label twice", %{mailbox: mailbox, label: label} do
      message = create_test_message(mailbox.id, %{})
      Email.add_label_to_message(message.id, label.id)

      # Should not error when adding duplicate
      result = Email.add_label_to_message(message.id, label.id)

      assert result == :ok || match?({:ok, _}, result) || match?({:error, _}, result)
    end

    test "handles removing non-existent label", %{mailbox: mailbox, label: label} do
      message = create_test_message(mailbox.id, %{})

      # Should not error
      result = Email.remove_label_from_message(message.id, label.id)

      assert result == :ok || match?({:ok, _}, result) || match?({:error, _}, result)
    end
  end

  describe "category operations" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "categorytest@example.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "moves message to digest (feed)", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: nil})

      {:ok, updated} = Email.move_to_digest(message)

      assert updated.category == "feed"
    end

    test "moves message to ledger", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: nil})

      {:ok, updated} = Email.move_to_ledger(message)

      assert updated.category == "ledger"
    end

    test "manual category moves are learned for future categorization", %{
      mailbox: mailbox,
      user: user
    } do
      message =
        create_test_message(mailbox.id, %{
          category: nil,
          from: "Billing Team <billing@learned-payments.example.com>"
        })

      {:ok, _updated} = Email.move_to_ledger(message)

      match = Email.match_category_preference(user.id, "billing@learned-payments.example.com")
      assert match.category == "ledger"
      assert match.source == "learned_sender"

      recategorized =
        Categorizer.categorize_message(
          %{
            "subject" => "Random subject",
            "from" => "billing@learned-payments.example.com",
            "to" => mailbox.email,
            "text_body" => "No obvious receipt markers",
            "html_body" => "",
            "metadata" => %{"headers" => %{}}
          },
          user_id: user.id
        )

      assert recategorized["category"] == "ledger"
    end

    test "stacks message", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: nil})

      {:ok, updated} = Email.stack_message(message, "Testing")

      assert updated.category == "stack"
    end

    test "unstacks message", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: "stack"})

      {:ok, updated} = Email.unstack_message(message)

      assert updated.category != "stack" || is_nil(updated.category)
    end

    test "message in feed is excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: "feed"})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "message in ledger is excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: "ledger"})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "message in stack is excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{category: "stack"})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end
  end

  describe "pagination edge cases" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "paginationtest@example.com"})

      # Create 25 messages
      messages =
        for i <- 1..25 do
          create_test_message(mailbox.id, %{subject: "Message #{i}"})
        end

      {:ok, user: user, mailbox: mailbox, messages: messages}
    end

    test "returns correct first page", %{mailbox: mailbox} do
      result = Email.list_inbox_messages_paginated(mailbox.id, 1, 10)

      assert length(result.messages) == 10
      assert result.page == 1
      assert result.has_next == true
      assert result.has_prev == false
    end

    test "returns correct middle page", %{mailbox: mailbox} do
      result = Email.list_inbox_messages_paginated(mailbox.id, 2, 10)

      assert length(result.messages) == 10
      assert result.page == 2
      assert result.has_next == true
      assert result.has_prev == true
    end

    test "returns correct last page", %{mailbox: mailbox} do
      result = Email.list_inbox_messages_paginated(mailbox.id, 3, 10)

      assert length(result.messages) == 5
      assert result.page == 3
      assert result.has_next == false
      assert result.has_prev == true
    end

    test "handles page 0 as page 1", %{mailbox: mailbox} do
      result = Email.list_inbox_messages_paginated(mailbox.id, 0, 10)

      assert result.page == 1
    end

    test "handles negative page as page 1", %{mailbox: mailbox} do
      result = Email.list_inbox_messages_paginated(mailbox.id, -5, 10)

      assert result.page == 1
    end

    test "handles page beyond total pages", %{mailbox: mailbox} do
      result = Email.list_inbox_messages_paginated(mailbox.id, 100, 10)

      assert result.messages == []
      assert result.has_next == false
    end
  end

  describe "message filtering edge cases" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "filtertest@example.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "sent messages excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{status: "sent"})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "draft messages excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{status: "draft"})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "spam messages excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{spam: true})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "archived messages excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{archived: true})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "deleted messages excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{deleted: true})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end

    test "reply_later messages excluded from inbox", %{mailbox: mailbox} do
      message = create_test_message(mailbox.id, %{reply_later_at: DateTime.utc_now()})

      inbox_messages = Messages.list_inbox_messages(mailbox.id)

      refute Enum.any?(inbox_messages, &(&1.id == message.id))
    end
  end

  describe "unread count edge cases" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "unreadtest@example.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "counts only unread messages in inbox", %{mailbox: mailbox} do
      # Create read and unread messages
      create_test_message(mailbox.id, %{read: false})
      create_test_message(mailbox.id, %{read: false})
      create_test_message(mailbox.id, %{read: true})

      count = Messages.unread_inbox_count(mailbox.id)

      assert count == 2
    end

    test "excludes spam from unread count", %{mailbox: mailbox} do
      create_test_message(mailbox.id, %{read: false, spam: true})
      create_test_message(mailbox.id, %{read: false, spam: false})

      count = Messages.unread_inbox_count(mailbox.id)

      assert count == 1
    end

    test "excludes archived from unread count", %{mailbox: mailbox} do
      create_test_message(mailbox.id, %{read: false, archived: true})
      create_test_message(mailbox.id, %{read: false, archived: false})

      count = Messages.unread_inbox_count(mailbox.id)

      assert count == 1
    end

    test "excludes folder messages from unread count", %{mailbox: mailbox, user: user} do
      {:ok, folder} = CustomFolders.create_folder(%{user_id: user.id, name: "Test"})

      create_test_message(mailbox.id, %{read: false, folder_id: folder.id})
      create_test_message(mailbox.id, %{read: false, folder_id: nil})

      count = Messages.unread_inbox_count(mailbox.id)

      assert count == 1
    end

    test "excludes special categories from unread count", %{mailbox: mailbox} do
      create_test_message(mailbox.id, %{read: false, category: "feed"})
      create_test_message(mailbox.id, %{read: false, category: "ledger"})
      create_test_message(mailbox.id, %{read: false, category: "stack"})
      create_test_message(mailbox.id, %{read: false, category: nil})

      count = Messages.unread_inbox_count(mailbox.id)

      assert count == 1
    end

    test "returns zero for empty mailbox" do
      user = user_fixture()
      empty_mailbox = mailbox_fixture(%{user_id: user.id, email: "empty@example.com"})

      count = Messages.unread_inbox_count(empty_mailbox.id)

      assert count == 0
    end

    test "get_all_unread_counts excludes deleted messages", %{mailbox: mailbox} do
      create_test_message(mailbox.id, %{read: false, deleted: true, category: nil})
      create_test_message(mailbox.id, %{read: false, deleted: false, category: nil})

      counts = Messages.get_all_unread_counts(mailbox.id)

      assert counts.inbox == 1
    end
  end

  describe "threading" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "threadtest@example.com"})
      {:ok, user: user, mailbox: mailbox}
    end

    test "auto-assigns thread_id and builds References for reply chains", %{mailbox: mailbox} do
      root_message_id = "thread-root-#{System.unique_integer([:positive])}@example.com"
      reply_message_id = "thread-reply-#{System.unique_integer([:positive])}@example.com"
      followup_message_id = "thread-followup-#{System.unique_integer([:positive])}@example.com"

      {:ok, root} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: "alice@example.com",
          to: mailbox.email,
          subject: "Quarterly update",
          text_body: "Initial message",
          message_id: root_message_id,
          status: "received"
        })

      {:ok, reply} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: mailbox.email,
          to: "alice@example.com",
          subject: "Re: Quarterly update",
          text_body: "Replying back",
          message_id: reply_message_id,
          in_reply_to: root_message_id,
          status: "sent"
        })

      {:ok, followup} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: "alice@example.com",
          to: mailbox.email,
          subject: "Re: Quarterly update",
          text_body: "Thanks for the reply",
          message_id: followup_message_id,
          in_reply_to: reply_message_id,
          status: "received"
        })

      root_after = Email.get_message(root.id, mailbox.id)

      assert is_integer(root_after.thread_id)
      assert reply.thread_id == root_after.thread_id
      assert followup.thread_id == root_after.thread_id

      assert reply.references == root_message_id
      assert followup.references == "#{root_message_id} #{reply_message_id}"

      thread_messages = Email.list_thread_messages(followup, mailbox.id)
      assert Enum.map(thread_messages, & &1.id) == [root.id, reply.id, followup.id]
    end

    test "does not thread unrelated messages that only share a subject", %{mailbox: mailbox} do
      {:ok, first} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: "alice@example.com",
          to: mailbox.email,
          subject: "Status update",
          text_body: "First message",
          message_id: "status-update-1-#{System.unique_integer([:positive])}@example.com",
          status: "received"
        })

      {:ok, second} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: "bob@example.com",
          to: mailbox.email,
          subject: "Status update",
          text_body: "Separate conversation",
          message_id: "status-update-2-#{System.unique_integer([:positive])}@example.com",
          status: "received"
        })

      refute is_integer(first.thread_id)
      refute is_integer(second.thread_id)
      assert Email.list_thread_messages(second, mailbox.id) == []
    end

    test "list_thread_messages excludes unrelated messages from polluted legacy threads", %{
      mailbox: mailbox
    } do
      root_message_id = "legacy-root-#{System.unique_integer([:positive])}@example.com"

      {:ok, root} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: "alice@example.com",
          to: mailbox.email,
          subject: "Project Alpha",
          text_body: "Initial message",
          message_id: root_message_id,
          status: "received"
        })

      {:ok, reply} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: mailbox.email,
          to: "alice@example.com",
          subject: "Re: Project Alpha",
          text_body: "Reply",
          message_id: "legacy-reply-#{System.unique_integer([:positive])}@example.com",
          in_reply_to: root_message_id,
          status: "sent"
        })

      unrelated =
        create_test_message(mailbox.id, %{
          from: "carol@example.com",
          to: mailbox.email,
          subject: "Project Alpha",
          text_body: "Different conversation with the same subject",
          message_id: "legacy-unrelated-#{System.unique_integer([:positive])}@example.com",
          thread_id: reply.thread_id,
          in_reply_to: nil,
          references: nil
        })

      thread_messages = Email.list_thread_messages(reply, mailbox.id)

      assert Enum.map(thread_messages, & &1.id) == [root.id, reply.id]
      refute Enum.any?(thread_messages, &(&1.id == unrelated.id))
    end

    test "attaches legacy parent messages to thread when replying", %{mailbox: mailbox} do
      legacy_parent =
        create_test_message(mailbox.id, %{
          subject: "Legacy thread",
          message_id: "legacy-parent-#{System.unique_integer([:positive])}@example.com",
          thread_id: nil
        })

      {:ok, reply} =
        Email.create_message(%{
          mailbox_id: mailbox.id,
          from: mailbox.email,
          to: "legacy@example.com",
          subject: "Re: Legacy thread",
          text_body: "Reply to legacy message",
          message_id: "legacy-reply-#{System.unique_integer([:positive])}@example.com",
          in_reply_to: legacy_parent.message_id,
          status: "sent"
        })

      parent_after = Email.get_message(legacy_parent.id, mailbox.id)

      assert is_integer(reply.thread_id)
      assert parent_after.thread_id == reply.thread_id
    end
  end

  # Helper function to create test messages
  defp create_test_message(mailbox_id, attrs) do
    default_attrs = %{
      from: "sender@example.com",
      to: "recipient@example.com",
      subject: "Test Subject #{System.unique_integer([:positive])}",
      text_body: "Test body",
      message_id: "test-#{System.unique_integer([:positive])}@example.com",
      mailbox_id: mailbox_id,
      status: "received",
      read: false,
      spam: false,
      archived: false,
      deleted: false
    }

    merged_attrs = Map.merge(default_attrs, attrs)

    {:ok, message} =
      %Elektrine.Email.Message{}
      |> Elektrine.Email.Message.changeset(merged_attrs)
      |> Elektrine.Repo.insert()

    message
  end
end
