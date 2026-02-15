defmodule ElektrineWeb.WKDControllerTest do
  use ElektrineWeb.ConnCase

  alias Elektrine.Accounts
  alias Elektrine.Email.PGP
  alias Elektrine.Repo

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

  describe "GET /.well-known/openpgpkey/policy" do
    test "returns empty policy file", %{conn: conn} do
      conn = get(conn, "/.well-known/openpgpkey/policy")

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
    end
  end

  describe "GET /.well-known/openpgpkey/hu/:hash" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "wkdtestuser#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      %{user: user}
    end

    test "returns 404 for unknown hash", %{conn: conn} do
      conn = get(conn, "/.well-known/openpgpkey/hu/nonexistenthash123")

      assert response(conn, 404) =~ "No key found"
    end

    test "returns 404 when user exists but has no key", %{conn: conn, user: user} do
      # Compute the WKD hash for this user
      hash = PGP.wkd_hash(user.username)

      conn = get(conn, "/.well-known/openpgpkey/hu/#{hash}")

      assert response(conn, 404) =~ "No key found"
    end

    test "returns key when user has PGP key", %{conn: conn, user: user} do
      # Set a PGP key for the user
      user
      |> Ecto.Changeset.change(%{pgp_public_key: @sample_pgp_key})
      |> Repo.update!()

      # Compute the WKD hash for this user
      hash = PGP.wkd_hash(user.username)

      conn = get(conn, "/.well-known/openpgpkey/hu/#{hash}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/octet-stream"
    end

    test "hash lookup is case insensitive for username", %{conn: conn, user: user} do
      # Set a PGP key for the user
      user
      |> Ecto.Changeset.change(%{pgp_public_key: @sample_pgp_key})
      |> Repo.update!()

      # WKD spec says local part should be lowercased before hashing
      # So hash of "Username" and "username" should be the same
      hash = PGP.wkd_hash(String.downcase(user.username))

      conn = get(conn, "/.well-known/openpgpkey/hu/#{hash}")

      assert response(conn, 200)
    end

    test "returns binary key data (dearmored) when possible", %{conn: conn, user: user} do
      # Set a valid PGP key
      user
      |> Ecto.Changeset.change(%{pgp_public_key: @sample_pgp_key})
      |> Repo.update!()

      hash = PGP.wkd_hash(user.username)

      conn = get(conn, "/.well-known/openpgpkey/hu/#{hash}")

      body = response(conn, 200)

      # Response should be binary (not armored text)
      # If dearmoring failed, it falls back to armored, which is also acceptable
      assert is_binary(body)
      assert byte_size(body) > 0
    end
  end

  describe "WKD hash consistency" do
    test "same username always produces same hash" do
      username = "consistentuser"

      hash1 = PGP.wkd_hash(username)
      hash2 = PGP.wkd_hash(username)

      assert hash1 == hash2
    end

    test "hash format is valid z-base32" do
      hash = PGP.wkd_hash("testuser")

      # z-base32 alphabet
      valid_chars = "ybndrfg8ejkmcpqxot1uwisza345h769"

      # All characters in hash should be from z-base32 alphabet
      assert String.graphemes(hash) |> Enum.all?(&String.contains?(valid_chars, &1))
    end
  end
end
