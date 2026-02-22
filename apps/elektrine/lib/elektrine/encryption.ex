defmodule Elektrine.Encryption do
  @moduledoc """
  Provides server-side encryption for messages and emails using AES-256-GCM.
  Includes blind keyword indexing for searchable content.
  """

  @aad "ElektrineV1"

  @doc """
  Encrypts content using AES-256-GCM with a user-specific key.
  Returns {encrypted_data, iv, tag} as base64-encoded strings.
  """
  def encrypt(plaintext, user_id) when is_binary(plaintext) and is_integer(user_id) do
    key = derive_key(user_id)
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        @aad,
        true
      )

    %{
      encrypted_data: Base.encode64(ciphertext),
      iv: Base.encode64(iv),
      tag: Base.encode64(tag)
    }
  end

  @doc """
  Decrypts content encrypted with encrypt/2.
  Takes a map with encrypted_data, iv, and tag (all base64-encoded).
  Handles both atom and string keys (for database retrieval).
  """
  def decrypt(encrypted_map, user_id) when is_map(encrypted_map) and is_integer(user_id) do
    key = derive_key(user_id)

    # Handle both atom and string keys (database stores as strings)
    encrypted_data = encrypted_map[:encrypted_data] || encrypted_map["encrypted_data"]
    iv_data = encrypted_map[:iv] || encrypted_map["iv"]
    tag_data = encrypted_map[:tag] || encrypted_map["tag"]

    ciphertext = Base.decode64!(encrypted_data)
    iv = Base.decode64!(iv_data)
    tag = Base.decode64!(tag_data)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  end

  @doc """
  Extracts keywords from text for search indexing.
  Removes common stop words and extracts hashtags.
  """
  def extract_keywords(text) when is_binary(text) do
    # Extract hashtags
    hashtags =
      Regex.scan(~r/#[a-zA-Z0-9_]+/, text)
      |> Enum.map(fn [tag] -> String.downcase(tag) end)

    # Extract words (3+ characters, not stop words)
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\w\s#]/, " ")
      |> String.split()
      |> Enum.filter(&(String.length(&1) >= 3))
      |> Enum.reject(&stop_word?/1)
      |> Enum.uniq()

    Enum.uniq(hashtags ++ words)
  end

  @doc """
  Creates a blind search index from keywords.
  Returns a list of hashed keywords that can be stored in the database.
  """
  def create_search_index(keywords, user_id) when is_list(keywords) and is_integer(user_id) do
    keywords
    |> Enum.map(&hash_keyword(&1, user_id))
    |> Enum.uniq()
  end

  @doc """
  Hashes a single keyword for search index lookup.
  """
  def hash_keyword(keyword, user_id) when is_binary(keyword) and is_integer(user_id) do
    salt = get_search_salt()
    key = derive_key(user_id)

    :crypto.mac(:hmac, :sha256, key <> salt, String.downcase(keyword))
    |> Base.encode64()
  end

  @doc """
  Creates search index from text content.
  Convenience function that extracts keywords and creates index.
  """
  def index_content(text, user_id) when is_binary(text) and is_integer(user_id) do
    text
    |> extract_keywords()
    |> create_search_index(user_id)
  end

  # Private functions

  defp derive_key(user_id) do
    # Use cached key if available, otherwise derive and cache
    Elektrine.Encryption.KeyCache.get_or_derive(user_id, fn ->
      master_secret = get_master_secret()
      salt = get_key_salt()

      # Use PBKDF2 to derive a user-specific key (expensive, but cached)
      :crypto.pbkdf2_hmac(
        :sha256,
        master_secret,
        salt <> Integer.to_string(user_id),
        100_000,
        32
      )
    end)
  end

  defp get_master_secret do
    # In production, this should come from environment variable or secure storage
    Application.get_env(:elektrine, :encryption_master_secret) ||
      raise "ENCRYPTION_MASTER_SECRET not configured"
  end

  defp get_key_salt do
    Application.get_env(:elektrine, :encryption_key_salt) ||
      raise "ENCRYPTION_KEY_SALT not configured"
  end

  defp get_search_salt do
    Application.get_env(:elektrine, :encryption_search_salt) ||
      raise "ENCRYPTION_SEARCH_SALT not configured"
  end

  defp stop_word?(word) do
    stop_words = ~w(
      the and but for not with you that this from they have
      are was were been will would could should may might
      can has had been being about into through during before
      after above below between under since until while when
      where which what who whom whose why how all each every
      both few more most other some such only own same than
      too very just now then here there
    )

    word in stop_words
  end
end
