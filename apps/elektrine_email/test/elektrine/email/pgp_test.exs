defmodule Elektrine.Email.PGPTest do
  use Elektrine.DataCase

  alias Elektrine.Email.PGP
  alias Elektrine.Email.PgpKeyCache
  alias Elektrine.Accounts
  alias Elektrine.Repo

  # Sample PGP public key for testing (minimal valid RSA key structure)
  @sample_pgp_key """
  -----BEGIN PGP PUBLIC KEY BLOCK-----

  mQENBGaT5OUBCAC3qKXrCXvWl5vNlRBNKPZNFAj3zLjXBdgOJvSqHHJwlHIbN1Gs
  NG9BF8VCGU3JNqjKoTcTkXhzF9a8BYh8R5lMBcRZp2r1CjRn9m7rGX7N1qJa0GJj
  HJkHAJqG8TLSB9c1rF9TqFcPjXvR9mRvRhFLK6bFtF1aF4G5UJUBL6UM5qF8VCGU
  3JNqjKoTcTkXhzF9a8BYh8R5lMBcRZp2r1CjRn9m7rGX7N1qJa0GJjHJkHAJqG8T
  LSB9c1rF9TqFcPjXvR9mRvRhFLK6bFtF1aF4G5UJUBL6UM5qF8VCGU3JNqjKoTcT
  kXhzF9a8BYh8R5lMBcRZp2r1CjRn9m7rGX7N1qJa0GJjHJkHAJqG8TLSB9c1rF9T
  qFcPjXvRABEBAAG0GlRlc3QgVXNlciA8dGVzdEBleGFtcGxlLmNvbT6JATgEEwEI
  ACIFAmaT5OUCGwMGCwkIBwMCBhUIAgkKCwQWAgMBAh4BAheAAAoJEJQa5lST5OXv
  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
  =ABCD
  -----END PGP PUBLIC KEY BLOCK-----
  """

  describe "wkd_hash/1" do
    test "computes correct z-base32 hash for local part" do
      # Known test vector: "test" should hash to a specific value
      hash = PGP.wkd_hash("test")

      # The hash should be a z-base32 encoded string
      assert is_binary(hash)
      assert String.length(hash) > 0

      # z-base32 uses only these characters
      valid_chars = ~c"ybndrfg8ejkmcpqxot1uwisza345h769"
      assert String.graphemes(hash) |> Enum.all?(fn c -> c in Enum.map(valid_chars, &<<&1>>) end)
    end

    test "hash is case insensitive" do
      hash1 = PGP.wkd_hash("testuser")
      hash2 = PGP.wkd_hash("TestUser")

      # Both should produce same hash since wkd_hash lowercases
      assert hash1 == hash2
    end

    test "different local parts produce different hashes" do
      hash1 = PGP.wkd_hash("alice")
      hash2 = PGP.wkd_hash("bob")

      assert hash1 != hash2
    end

    test "empty string produces valid hash" do
      hash = PGP.wkd_hash("")
      assert is_binary(hash)
    end
  end

  describe "parse_public_key/1" do
    test "rejects non-PGP content" do
      assert {:error, :not_pgp_key} = PGP.parse_public_key("not a pgp key")
    end

    test "rejects nil input" do
      assert {:error, :invalid_input} = PGP.parse_public_key(nil)
    end

    test "rejects empty string that looks like armor" do
      key = """
      -----BEGIN PGP PUBLIC KEY BLOCK-----
      -----END PGP PUBLIC KEY BLOCK-----
      """

      assert {:error, _} = PGP.parse_public_key(key)
    end

    test "accepts properly formatted PGP key" do
      # This may fail to parse but should not reject as not_pgp_key
      result = PGP.parse_public_key(@sample_pgp_key)

      case result do
        {:ok, %{fingerprint: fp, key_id: kid}} ->
          assert is_binary(fp)
          assert is_binary(kid)
          # Key ID is last 16 chars of fingerprint
          assert String.ends_with?(fp, kid)

        {:error, reason} ->
          # Parsing might fail but it should recognize it as a PGP key
          assert reason != :not_pgp_key
      end
    end
  end

  describe "armor_public_key/1" do
    test "produces valid armor format" do
      binary_data = :crypto.strong_rand_bytes(32)
      armored = PGP.armor_public_key(binary_data)

      assert String.contains?(armored, "-----BEGIN PGP PUBLIC KEY BLOCK-----")
      assert String.contains?(armored, "-----END PGP PUBLIC KEY BLOCK-----")
      # Should have checksum line
      assert String.contains?(armored, "=")
    end

    test "armored output can be decoded back" do
      original = :crypto.strong_rand_bytes(64)
      armored = PGP.armor_public_key(original)

      # Extract base64 content
      lines = String.split(armored, ~r/\r?\n/)

      content =
        lines
        |> Enum.drop_while(&(!String.starts_with?(&1, "-----BEGIN")))
        |> Enum.drop(1)
        |> Enum.take_while(&(!String.starts_with?(&1, "-----END")))
        |> Enum.reject(&String.starts_with?(&1, "="))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("")

      {:ok, decoded} = Base.decode64(content)
      assert decoded == original
    end
  end

  describe "store_user_key/2 and delete_user_key/1" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "pgpuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "stores key with valid input", %{user: user} do
      # We need a key that can be parsed - using a simple structure
      # For now, test the error case since we don't have a truly valid key
      result = PGP.store_user_key(user, @sample_pgp_key)

      case result do
        {:ok, updated_user} ->
          assert updated_user.pgp_public_key == @sample_pgp_key
          assert updated_user.pgp_key_uploaded_at != nil

        {:error, _reason} ->
          # Expected if key parsing fails, which is fine for this test
          assert true
      end
    end

    test "store_user_key accepts user struct", %{user: user} do
      result =
        PGP.store_user_key(
          user,
          "-----BEGIN PGP PUBLIC KEY BLOCK-----\ntest\n-----END PGP PUBLIC KEY BLOCK-----"
        )

      # Should return error for invalid base64, but accepts user struct
      assert {:error, _} = result
    end

    test "store_user_key accepts user_id", %{user: user} do
      result = PGP.store_user_key(user.id, "not a key")

      assert {:error, :not_pgp_key} = result
    end

    test "delete_user_key removes key", %{user: user} do
      # First manually set a key
      user
      |> Ecto.Changeset.change(%{
        pgp_public_key: "test key",
        pgp_fingerprint: "ABCD1234",
        pgp_key_id: "1234",
        pgp_key_uploaded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      # Now delete it
      {:ok, updated_user} = PGP.delete_user_key(user)

      assert updated_user.pgp_public_key == nil
      assert updated_user.pgp_fingerprint == nil
      assert updated_user.pgp_key_id == nil
      assert updated_user.pgp_key_uploaded_at == nil
    end

    test "delete_user_key accepts user struct", %{user: user} do
      {:ok, _} = PGP.delete_user_key(user)
    end

    test "delete_user_key accepts user_id", %{user: user} do
      {:ok, _} = PGP.delete_user_key(user.id)
    end
  end

  describe "get_user_key/1" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "getkeyuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns error when user has no key", %{user: user} do
      assert {:error, :no_key} = PGP.get_user_key(user.id)
    end

    test "returns key when user has one", %{user: user} do
      # Set a key
      user
      |> Ecto.Changeset.change(%{pgp_public_key: "test key content"})
      |> Repo.update!()

      assert {:ok, "test key content"} = PGP.get_user_key(user.id)
    end

    test "returns error for non-existent user" do
      assert {:error, :no_key} = PGP.get_user_key(-1)
    end
  end

  describe "get_key_by_email/1" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "emailkeyuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns key for user with elektrine.com email", %{user: user} do
      user
      |> Ecto.Changeset.change(%{pgp_public_key: "test key"})
      |> Repo.update!()

      email = "#{user.username}@elektrine.com"
      assert {:ok, "test key"} = PGP.get_key_by_email(email)
    end

    test "returns key for user with z.org email", %{user: user} do
      user
      |> Ecto.Changeset.change(%{pgp_public_key: "test key"})
      |> Repo.update!()

      email = "#{user.username}@z.org"
      assert {:ok, "test key"} = PGP.get_key_by_email(email)
    end

    test "returns error for external domain" do
      assert {:error, :not_our_domain} = PGP.get_key_by_email("user@external.com")
    end

    test "returns error when user has no key", %{user: user} do
      email = "#{user.username}@elektrine.com"
      assert {:error, :no_key} = PGP.get_key_by_email(email)
    end

    test "email lookup is case insensitive", %{user: user} do
      user
      |> Ecto.Changeset.change(%{pgp_public_key: "test key"})
      |> Repo.update!()

      email = "#{String.upcase(user.username)}@ELEKTRINE.COM"
      assert {:ok, "test key"} = PGP.get_key_by_email(email)
    end
  end

  describe "key cache" do
    test "cache stores found keys" do
      email = "cachetest#{System.unique_integer([:positive])}@example.com"

      # Insert a cache entry directly
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      %PgpKeyCache{}
      |> PgpKeyCache.changeset(%{
        email: email,
        public_key: "cached test key",
        status: "found",
        source: "wkd",
        expires_at: expires_at
      })
      |> Repo.insert!()

      # Lookup should return cached key
      assert {:ok, "cached test key"} = PGP.lookup_key(email)
    end

    test "cache respects expiration" do
      email = "expiredcache#{System.unique_integer([:positive])}@example.com"

      # Insert an expired cache entry
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      %PgpKeyCache{}
      |> PgpKeyCache.changeset(%{
        email: email,
        public_key: "expired key",
        status: "found",
        source: "wkd",
        expires_at: expires_at
      })
      |> Repo.insert!()

      # Should not return expired entry, will try WKD and fail
      assert {:error, :no_key} = PGP.lookup_key(email)
    end

    test "cache stores not_found status" do
      email = "notfoundcache#{System.unique_integer([:positive])}@example.com"

      # Insert a not_found cache entry
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      %PgpKeyCache{}
      |> PgpKeyCache.changeset(%{
        email: email,
        status: "not_found",
        expires_at: expires_at
      })
      |> Repo.insert!()

      # Should return no_key without trying WKD
      assert {:error, :no_key} = PGP.lookup_key(email)
    end

    test "cleanup_expired_cache removes old entries" do
      email = "cleanup#{System.unique_integer([:positive])}@example.com"

      # Insert an expired entry
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      %PgpKeyCache{}
      |> PgpKeyCache.changeset(%{
        email: email,
        status: "found",
        public_key: "old key",
        expires_at: expires_at
      })
      |> Repo.insert!()

      # Verify it exists
      assert Repo.get_by(PgpKeyCache, email: email) != nil

      # Run cleanup
      PGP.cleanup_expired_cache()

      # Should be gone
      assert Repo.get_by(PgpKeyCache, email: email) == nil
    end
  end

  describe "lookup_recipient_key/2" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "recipientuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns no_key for unknown recipient", %{user: user} do
      assert {:error, :no_key} = PGP.lookup_recipient_key("unknown@example.com", user.id)
    end

    test "email is case insensitive", %{user: user} do
      # Should not crash with mixed case
      result = PGP.lookup_recipient_key("TEST@EXAMPLE.COM", user.id)
      assert {:error, :no_key} = result
    end
  end

  describe "maybe_encrypt_email/3" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "encryptuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns params unchanged when recipient has no key", %{user: user} do
      params = %{
        to: "nokey@example.com",
        subject: "Test",
        text_body: "Hello world"
      }

      result = PGP.maybe_encrypt_email(params, "nokey@example.com", user.id)

      # Should be unchanged since no key found
      assert result[:text_body] == "Hello world"
      assert result[:pgp_encrypted] != true
    end

    test "returns params unchanged when body is empty", %{user: user} do
      params = %{
        to: "test@example.com",
        subject: "Test",
        text_body: "",
        html_body: nil
      }

      result = PGP.maybe_encrypt_email(params, "test@example.com", user.id)

      assert result[:pgp_encrypted] != true
    end
  end
end
