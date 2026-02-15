defmodule Elektrine.EncryptionTest do
  use ExUnit.Case, async: true
  alias Elektrine.Encryption

  @user_id 123

  describe "encrypt/2 and decrypt/2" do
    test "encrypts and decrypts plaintext successfully" do
      plaintext = "This is a secret message"

      encrypted = Encryption.encrypt(plaintext, @user_id)

      assert is_map(encrypted)
      assert Map.has_key?(encrypted, :encrypted_data)
      assert Map.has_key?(encrypted, :iv)
      assert Map.has_key?(encrypted, :tag)
      assert encrypted.encrypted_data != plaintext

      {:ok, decrypted} = Encryption.decrypt(encrypted, @user_id)
      assert decrypted == plaintext
    end

    test "encrypts same plaintext differently each time (due to random IV)" do
      plaintext = "Same message"

      encrypted1 = Encryption.encrypt(plaintext, @user_id)
      encrypted2 = Encryption.encrypt(plaintext, @user_id)

      # Different IVs mean different ciphertexts
      assert encrypted1.iv != encrypted2.iv
      assert encrypted1.encrypted_data != encrypted2.encrypted_data

      # But both decrypt to same plaintext
      {:ok, decrypted1} = Encryption.decrypt(encrypted1, @user_id)
      {:ok, decrypted2} = Encryption.decrypt(encrypted2, @user_id)
      assert decrypted1 == plaintext
      assert decrypted2 == plaintext
    end

    test "decryption fails with wrong user_id" do
      plaintext = "Secret for user 123"
      encrypted = Encryption.encrypt(plaintext, @user_id)

      wrong_user_id = 456
      result = Encryption.decrypt(encrypted, wrong_user_id)

      assert result == {:error, :decryption_failed}
    end

    test "decryption fails with tampered ciphertext" do
      plaintext = "Original message"
      encrypted = Encryption.encrypt(plaintext, @user_id)

      # Tamper with encrypted data
      tampered = %{encrypted | encrypted_data: Base.encode64("tampered data")}

      result = Encryption.decrypt(tampered, @user_id)
      assert result == {:error, :decryption_failed}
    end

    test "handles empty string" do
      plaintext = ""
      encrypted = Encryption.encrypt(plaintext, @user_id)
      {:ok, decrypted} = Encryption.decrypt(encrypted, @user_id)

      assert decrypted == ""
    end

    test "handles unicode characters" do
      plaintext = "Hello 世界 🌍 Привет"
      encrypted = Encryption.encrypt(plaintext, @user_id)
      {:ok, decrypted} = Encryption.decrypt(encrypted, @user_id)

      assert decrypted == plaintext
    end

    test "handles large text" do
      plaintext = String.duplicate("A", 10_000)
      encrypted = Encryption.encrypt(plaintext, @user_id)
      {:ok, decrypted} = Encryption.decrypt(encrypted, @user_id)

      assert decrypted == plaintext
    end
  end

  describe "extract_keywords/1" do
    test "extracts words 3+ characters" do
      text = "The quick brown fox jumps"
      keywords = Encryption.extract_keywords(text)

      assert "quick" in keywords
      assert "brown" in keywords
      assert "jumps" in keywords
      # 3 chars, should be extracted
      assert "fox" in keywords
      # Stop word
      refute "the" in keywords
    end

    test "extracts hashtags" do
      text = "Check out #elixir and #phoenix frameworks"
      keywords = Encryption.extract_keywords(text)

      assert "#elixir" in keywords
      assert "#phoenix" in keywords
    end

    test "removes stop words" do
      text = "the and but for not with you that this from"
      keywords = Encryption.extract_keywords(text)

      # All stop words should be filtered out
      assert keywords == []
    end

    test "converts to lowercase" do
      text = "Elixir PHOENIX Framework"
      keywords = Encryption.extract_keywords(text)

      assert "elixir" in keywords
      assert "phoenix" in keywords
      assert "framework" in keywords
      refute "Elixir" in keywords
      refute "PHOENIX" in keywords
    end

    test "removes duplicates" do
      text = "test test test testing"
      keywords = Encryption.extract_keywords(text)

      # Should only appear once each
      assert Enum.count(keywords, &(&1 == "test")) == 1
      assert Enum.count(keywords, &(&1 == "testing")) == 1
    end

    test "handles mixed content with special characters" do
      text = "Email: user@example.com, phone: 555-1234, #important!"
      keywords = Encryption.extract_keywords(text)

      assert "#important" in keywords
      assert "email" in keywords
    end
  end

  describe "hash_keyword/2" do
    test "produces consistent hash for same keyword and user" do
      keyword = "test"

      hash1 = Encryption.hash_keyword(keyword, @user_id)
      hash2 = Encryption.hash_keyword(keyword, @user_id)

      assert hash1 == hash2
    end

    test "produces different hashes for different users" do
      keyword = "test"
      user1_id = 123
      user2_id = 456

      hash1 = Encryption.hash_keyword(keyword, user1_id)
      hash2 = Encryption.hash_keyword(keyword, user2_id)

      assert hash1 != hash2
    end

    test "produces different hashes for different keywords" do
      hash1 = Encryption.hash_keyword("test", @user_id)
      hash2 = Encryption.hash_keyword("demo", @user_id)

      assert hash1 != hash2
    end

    test "is case-insensitive" do
      hash1 = Encryption.hash_keyword("test", @user_id)
      hash2 = Encryption.hash_keyword("TEST", @user_id)
      hash3 = Encryption.hash_keyword("Test", @user_id)

      assert hash1 == hash2
      assert hash2 == hash3
    end
  end

  describe "create_search_index/2" do
    test "creates hash for each keyword" do
      keywords = ["elixir", "phoenix", "test"]
      search_index = Encryption.create_search_index(keywords, @user_id)

      assert length(search_index) == 3
      assert Enum.all?(search_index, &is_binary/1)
    end

    test "removes duplicate hashes" do
      keywords = ["test", "test", "demo"]
      search_index = Encryption.create_search_index(keywords, @user_id)

      # Should only have 2 unique hashes
      assert length(search_index) == 2
    end

    test "handles empty keyword list" do
      search_index = Encryption.create_search_index([], @user_id)
      assert search_index == []
    end
  end

  describe "index_content/2" do
    test "extracts keywords and creates search index" do
      text = "This is a test message about #elixir programming"
      search_index = Encryption.index_content(text, @user_id)

      assert is_list(search_index)
      assert search_index != []
      assert Enum.all?(search_index, &is_binary/1)
    end

    test "creates searchable index that can find keywords" do
      text = "Important meeting about #project tomorrow"
      search_index = Encryption.index_content(text, @user_id)

      # Hash for "important" should be in index
      important_hash = Encryption.hash_keyword("important", @user_id)
      assert important_hash in search_index

      # Hash for "meeting" should be in index
      meeting_hash = Encryption.hash_keyword("meeting", @user_id)
      assert meeting_hash in search_index

      # Hash for "#project" should be in index
      project_hash = Encryption.hash_keyword("#project", @user_id)
      assert project_hash in search_index
    end

    test "index is user-specific" do
      text = "Secret message"

      index1 = Encryption.index_content(text, 123)
      index2 = Encryption.index_content(text, 456)

      # Same text, different users = different indexes
      assert index1 != index2
    end
  end

  describe "key derivation" do
    test "different users have different encryption keys (indirect test)" do
      plaintext = "Same message for different users"
      user1_id = 100
      user2_id = 200

      encrypted1 = Encryption.encrypt(plaintext, user1_id)
      encrypted2 = Encryption.encrypt(plaintext, user2_id)

      # User 2 can't decrypt user 1's message
      result = Encryption.decrypt(encrypted1, user2_id)
      assert result == {:error, :decryption_failed}

      # User 1 can't decrypt user 2's message
      result = Encryption.decrypt(encrypted2, user1_id)
      assert result == {:error, :decryption_failed}
    end
  end
end
