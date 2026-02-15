defmodule Elektrine.EncryptedSearchTest do
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

  describe "blind index search" do
    test "finds messages by keyword using encrypted index", %{
      user1: user1,
      conversation: conversation
    } do
      # Create messages with different content
      {:ok, _msg1} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Meeting scheduled for tomorrow"
        )

      {:ok, _msg2} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Important project deadline"
        )

      {:ok, _msg3} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Random other message"
        )

      # Search for "meeting"
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "meeting"
        )

      # Should find only the message containing "meeting"
      assert results != []
      assert Enum.any?(results, fn m -> m.content =~ "Meeting" end)
    end

    test "search works with exact keyword matches", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Testing the search functionality"
        )

      # Search with exact keyword match (blind index only supports exact matches)
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "testing"
        )

      # Should find the message
      assert results != []
      assert Enum.any?(results, fn m -> m.content =~ "Testing" end)
    end

    test "search is case-insensitive", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Important PROJECT deadline"
        )

      # Search with lowercase
      {:ok, results1} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "project"
        )

      # Search with uppercase
      {:ok, results2} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "PROJECT"
        )

      # Both should find the message
      assert results1 != []
      assert results2 != []
    end

    test "finds messages by hashtag", %{user1: user1, conversation: conversation} do
      {:ok, _msg1} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Working on #project today"
        )

      {:ok, _msg2} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Need to finish #deadline tasks"
        )

      # Search for hashtag
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "#project"
        )

      # Should find the message with #project
      assert results != []
      assert Enum.any?(results, fn m -> m.content =~ "#project" end)
    end

    test "returns decrypted content in search results", %{
      user1: user1,
      conversation: conversation
    } do
      secret_content = "This is secret content for search"

      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          secret_content
        )

      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "secret"
        )

      # Results should be decrypted
      assert Enum.any?(results, fn m -> m.content == secret_content end)
    end

    test "search doesn't return results from other users' conversations", %{
      user1: user1,
      user2: user2,
      conversation: conversation
    } do
      # Create another user and conversation
      {:ok, user3} =
        Accounts.create_user(%{
          username: "user3",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, other_conv} = Messaging.create_dm_conversation(user2.id, user3.id)

      # Create message in first conversation
      {:ok, _msg1} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "secretword in first conversation"
        )

      # Create message in second conversation
      {:ok, _msg2} =
        Messaging.create_text_message(
          other_conv.id,
          user2.id,
          "secretword in second conversation"
        )

      # Search in first conversation
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "secretword"
        )

      # Should only find message from first conversation
      assert length(results) == 1
      assert hd(results).conversation_id == conversation.id
    end

    test "search filters out short words (stop words)", %{
      user1: user1,
      conversation: conversation
    } do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "The quick brown fox jumps"
        )

      # Searching for stop words may not work with blind index
      # But searching for "quick" should work
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "quick"
        )

      assert results != []
    end
  end

  describe "search with multiple keywords" do
    test "finds messages matching query terms", %{user1: user1, conversation: conversation} do
      {:ok, _msg1} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Project meeting tomorrow morning"
        )

      {:ok, _msg2} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Budget review meeting next week"
        )

      # Search for "meeting"
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "meeting"
        )

      # Should find both messages
      assert length(results) >= 2
    end

    test "handles special characters in search", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Email: user@example.com"
        )

      # Search should handle special characters
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "email"
        )

      assert results != []
    end
  end

  describe "search index integrity" do
    test "search index contains expected keyword hashes", %{
      user1: user1,
      conversation: conversation
    } do
      content = "Important meeting about project deadline"

      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      # Reload from database
      db_message = Repo.get(Message, message.id)

      # Calculate expected hashes
      important_hash = Elektrine.Encryption.hash_keyword("important", user1.id)
      meeting_hash = Elektrine.Encryption.hash_keyword("meeting", user1.id)
      project_hash = Elektrine.Encryption.hash_keyword("project", user1.id)
      deadline_hash = Elektrine.Encryption.hash_keyword("deadline", user1.id)

      # Verify all keyword hashes are in index
      assert important_hash in db_message.search_index
      assert meeting_hash in db_message.search_index
      assert project_hash in db_message.search_index
      assert deadline_hash in db_message.search_index
    end

    test "search index updates when message is edited", %{
      user1: user1,
      conversation: conversation
    } do
      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Original content with keyword1"
        )

      original_db_message = Repo.get(Message, message.id)
      keyword1_hash = Elektrine.Encryption.hash_keyword("keyword1", user1.id)
      assert keyword1_hash in original_db_message.search_index

      # Edit message
      {:ok, _updated} =
        Messaging.edit_message(
          message.id,
          user1.id,
          "Updated content with keyword2"
        )

      updated_db_message = Repo.get(Message, message.id)
      keyword2_hash = Elektrine.Encryption.hash_keyword("keyword2", user1.id)

      # New keyword should be in index
      assert keyword2_hash in updated_db_message.search_index
    end

    test "search index is user-specific", %{
      user1: user1,
      user2: user2,
      conversation: conversation
    } do
      content = "Shared message content"

      {:ok, msg1} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          content
        )

      {:ok, msg2} =
        Messaging.create_text_message(
          conversation.id,
          user2.id,
          content
        )

      db_msg1 = Repo.get(Message, msg1.id)
      db_msg2 = Repo.get(Message, msg2.id)

      # Same content, different users = different search indexes
      assert db_msg1.search_index != db_msg2.search_index

      # But each user's keywords should match their own hash
      user1_hash = Elektrine.Encryption.hash_keyword("shared", user1.id)
      user2_hash = Elektrine.Encryption.hash_keyword("shared", user2.id)

      assert user1_hash in db_msg1.search_index
      assert user2_hash in db_msg2.search_index
      refute user1_hash in db_msg2.search_index
      refute user2_hash in db_msg1.search_index
    end
  end

  describe "search performance" do
    test "search works with large number of messages", %{user1: user1, conversation: conversation} do
      # Create multiple messages
      for i <- 1..20 do
        content =
          if rem(i, 5) == 0 do
            "Message #{i} with searchterm"
          else
            "Message #{i} without special keyword"
          end

        {:ok, _msg} =
          Messaging.create_text_message(
            conversation.id,
            user1.id,
            content
          )
      end

      # Search should find only messages with "searchterm"
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "searchterm"
        )

      # Should find 4 messages (5, 10, 15, 20)
      assert length(results) == 4
      assert Enum.all?(results, fn m -> m.content =~ "searchterm" end)
    end

    test "very short search query", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Some content"
        )

      # Very short (less than 2 chars) search - behavior depends on implementation
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "x"
        )

      # Should handle gracefully (may return empty or match single-char terms)
      assert is_list(results)
    end

    test "search with very short query", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Message with short word: OK"
        )

      # Very short search terms may not be indexed
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "OK"
        )

      # Behavior depends on implementation (min 3 chars for indexing)
      # This tests that it doesn't crash
      assert is_list(results)
    end
  end

  describe "search with unicode and special content" do
    test "searches unicode content", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Unicode content: 世界 Привет"
        )

      # Search for unicode term
      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "unicode"
        )

      assert results != []
    end

    test "searches messages with emojis", %{user1: user1, conversation: conversation} do
      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          user1.id,
          "Happy birthday 🎉🎂 celebration"
        )

      {:ok, results} =
        Messaging.search_messages_in_conversation(
          conversation.id,
          user1.id,
          "celebration"
        )

      assert results != []
      assert Enum.any?(results, fn m -> m.content =~ "🎉" end)
    end
  end
end
