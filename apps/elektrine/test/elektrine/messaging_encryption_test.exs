defmodule Elektrine.MessagingEncryptionTest do
  use Elektrine.DataCase

  alias Elektrine.{Messaging, Accounts, Repo}
  alias Elektrine.Messaging.Message

  setup do
    # Create test users
    {:ok, user1} =
      Accounts.create_user(%{
        username: "user1",
        password: "password123456",
        password_confirmation: "password123456"
      })

    {:ok, user2} =
      Accounts.create_user(%{
        username: "user2",
        password: "password123456",
        password_confirmation: "password123456"
      })

    # Create a conversation
    {:ok, conversation} = Messaging.create_dm_conversation(user1.id, user2.id)

    %{user1: user1, user2: user2, conversation: conversation}
  end

  describe "message encryption on creation" do
    test "encrypts message content when creating", %{user1: user1, conversation: conversation} do
      content = "This is a secret message"

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      # Reload from database to check stored values
      db_message = Repo.get(Message, message.id)

      # Encrypted content should be stored
      assert db_message.encrypted_content != nil
      assert is_map(db_message.encrypted_content)
      assert Map.has_key?(db_message.encrypted_content, "encrypted_data")
      assert Map.has_key?(db_message.encrypted_content, "iv")
      assert Map.has_key?(db_message.encrypted_content, "tag")

      # Search index should be created
      assert is_list(db_message.search_index)
      assert db_message.search_index != []

      # Plaintext should NOT be stored in database
      assert db_message.content == nil
    end

    test "returned message contains decrypted content", %{
      user1: user1,
      conversation: conversation
    } do
      content = "Hello from test"

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      # Returned message should have decrypted content
      assert message.content == content
    end

    test "creates searchable index with keywords", %{user1: user1, conversation: conversation} do
      content = "Meeting tomorrow about #project deadline"

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      db_message = Repo.get(Message, message.id)

      # Search index should contain hashes for keywords
      assert db_message.search_index != []

      # Verify we can find the message by keyword
      meeting_hash = Elektrine.Encryption.hash_keyword("meeting", user1.id)
      assert meeting_hash in db_message.search_index

      project_hash = Elektrine.Encryption.hash_keyword("#project", user1.id)
      assert project_hash in db_message.search_index
    end

    test "encrypts media message captions", %{user1: user1, conversation: conversation} do
      content = "Check out this photo!"
      media_urls = ["attachments/photo.jpg"]

      {:ok, message} =
        Messaging.create_media_message(
          conversation.id,
          user1.id,
          media_urls,
          content
        )

      db_message = Repo.get(Message, message.id)

      # Caption should be encrypted
      assert db_message.encrypted_content != nil
      assert message.content == content
    end

    test "handles empty content gracefully", %{user1: user1, conversation: conversation} do
      media_urls = ["attachments/photo.jpg"]

      {:ok, message} =
        Messaging.create_media_message(
          conversation.id,
          user1.id,
          media_urls,
          nil
        )

      # Should not crash, encrypted_content should be nil
      assert message.encrypted_content == nil
    end
  end

  describe "message decryption on retrieval" do
    test "decrypts messages when loading conversation", %{
      user1: user1,
      user2: user2,
      conversation: conversation
    } do
      # Create some messages
      {:ok, _msg1} = Messaging.create_text_message(conversation.id, user1.id, "First message")
      {:ok, _msg2} = Messaging.create_text_message(conversation.id, user2.id, "Second message")

      # Load conversation
      {:ok, loaded_conversation} = Messaging.get_conversation!(conversation.id, user1.id)

      messages = loaded_conversation.messages

      # Messages should be decrypted
      assert Enum.any?(messages, fn m -> m.content == "First message" end)
      assert Enum.any?(messages, fn m -> m.content == "Second message" end)
    end

    test "decrypts messages when searching", %{user1: user1, conversation: conversation} do
      # Create test message
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "searchable keyword test"
        )

      # Search for message
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "searchable"
        )

      # Should find and decrypt the message
      assert results != []
      assert Enum.any?(results, fn m -> m.content =~ "searchable" end)
    end

    test "decrypts edited messages", %{user1: user1, conversation: conversation} do
      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Original content"
        )

      # Edit the message
      new_content = "Updated content"
      {:ok, updated_message} = Messaging.edit_message(message.id, user1.id, new_content)

      # Should be encrypted in database
      db_message = Repo.get(Message, message.id)
      assert db_message.encrypted_content != nil

      # But decrypted when returned
      assert updated_message.content == new_content
    end
  end

  describe "message list decryption" do
    test "decrypts conversation list preview messages", %{
      user1: user1,
      user2: user2,
      conversation: conversation
    } do
      last_message_content = "Latest message preview"

      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user2.id,
          last_message_content
        )

      # List conversations
      conversations = Messaging.list_conversations(user1.id)

      # Find our conversation
      conv = Enum.find(conversations, fn c -> c.id == conversation.id end)

      # Last message should be decrypted
      assert conv.messages != []
      [last_msg | _] = conv.messages
      assert last_msg.content == last_message_content
    end
  end

  describe "encryption with special content" do
    test "encrypts unicode and emoji content", %{user1: user1, conversation: conversation} do
      content = "Hello 世界 🌍 Привет 😊"

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      # Should encrypt and decrypt properly
      assert message.content == content

      # Reload and decrypt
      {:ok, loaded_conv} = Messaging.get_conversation!(conversation.id, user1.id)
      [loaded_msg | _] = loaded_conv.messages
      assert loaded_msg.content == content
    end

    test "encrypts long messages", %{user1: user1, conversation: conversation} do
      content = String.duplicate("Long message content. ", 100)

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      assert message.content == content

      db_message = Repo.get(Message, message.id)
      assert db_message.encrypted_content != nil
    end

    test "encrypts messages with hashtags", %{user1: user1, conversation: conversation} do
      content = "Important #project #deadline #meeting notes"

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      # Content should be encrypted and searchable by hashtags
      db_message = Repo.get(Message, message.id)

      project_hash = Elektrine.Encryption.hash_keyword("#project", user1.id)
      deadline_hash = Elektrine.Encryption.hash_keyword("#deadline", user1.id)
      meeting_hash = Elektrine.Encryption.hash_keyword("#meeting", user1.id)

      assert project_hash in db_message.search_index
      assert deadline_hash in db_message.search_index
      assert meeting_hash in db_message.search_index
    end
  end

  describe "system messages" do
    test "system messages validation", %{conversation: conversation} do
      # System messages don't have sender_id, so they can't be encrypted
      # This is expected behavior - system messages should not be encrypted
      changeset = Message.system_changeset(conversation.id, "User joined the conversation")

      # System changeset should not be valid without sender_id
      # since sender_id is required for encryption
      refute changeset.valid?
    end
  end
end
