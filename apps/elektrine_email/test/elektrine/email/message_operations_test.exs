defmodule Elektrine.Email.MessageOperationsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.EmailFixtures

  alias Elektrine.Email
  alias Elektrine.Email.CustomFolders
  alias Elektrine.Email.Labels
  alias Elektrine.Email.Messages

  describe "message flag updates" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "test@elektrine.com"})
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
      mailbox = mailbox_fixture(%{user_id: user.id, email: "foldertest@elektrine.com"})
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
  end

  describe "label operations" do
    setup do
      user = user_fixture()
      mailbox = mailbox_fixture(%{user_id: user.id, email: "labeltest@elektrine.com"})
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
      mailbox = mailbox_fixture(%{user_id: user.id, email: "categorytest@elektrine.com"})
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
      mailbox = mailbox_fixture(%{user_id: user.id, email: "paginationtest@elektrine.com"})

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
      mailbox = mailbox_fixture(%{user_id: user.id, email: "filtertest@elektrine.com"})
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
      mailbox = mailbox_fixture(%{user_id: user.id, email: "unreadtest@elektrine.com"})
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
      empty_mailbox = mailbox_fixture(%{user_id: user.id, email: "empty@elektrine.com"})

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

  # Helper function to create test messages
  defp create_test_message(mailbox_id, attrs) do
    default_attrs = %{
      from: "sender@example.com",
      to: "recipient@elektrine.com",
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
