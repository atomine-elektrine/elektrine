defmodule Elektrine.Email.PGPReceiveTest do
  @moduledoc """
  Tests for receiving PGP-encrypted emails.
  """
  use Elektrine.DataCase

  alias Elektrine.Email
  alias Elektrine.Email.Receiver
  alias Elektrine.Accounts

  # Sample PGP encrypted message (minimal structure for testing)
  @sample_pgp_message """
  -----BEGIN PGP MESSAGE-----

  hQEMA1234567890ABCAQ/9H7B3c4V8mKTk2YpHvWpLKF6
  q2tY8QjXJk7E8RRfXvKFxJ3W9nMPQz1B2NrS5T8UwVxY
  Z0aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3a4B
  5cD6eF7gH8iJ9kL0mN1oP2qR3sT4uV5wX6yZ7a8B9cD0
  =ABCD
  -----END PGP MESSAGE-----
  """

  @sample_pgp_signed_message """
  -----BEGIN PGP SIGNED MESSAGE-----
  Hash: SHA256

  This is a signed message.
  -----BEGIN PGP SIGNATURE-----

  iQEzBAEBCAAdFiEEtest123456789ABCDEFGHIJKLMNOPQRSTUVWXYZab
  =1234
  -----END PGP SIGNATURE-----
  """

  @sample_pgp_inline_message """
  Hello,

  Here is my encrypted reply:

  -----BEGIN PGP MESSAGE-----

  hQEMA1234567890ABCAQ/9H7B3c4V8mKTk2YpHvWpLKF6
  =ABCD
  -----END PGP MESSAGE-----

  Best regards,
  Alice
  """

  describe "receiving PGP-encrypted emails" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "pgpreceiver#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      mailbox = Email.get_user_mailbox(user.id)

      %{user: user, mailbox: mailbox}
    end

    test "stores PGP-encrypted email body", %{mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Encrypted Message",
        "plain_body" => @sample_pgp_message,
        "html_body" => nil,
        "message_id" => "pgp-test-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id

      # Decrypt and verify the body was stored
      decrypted = Email.Message.decrypt_content(message)
      assert String.contains?(decrypted.text_body, "-----BEGIN PGP MESSAGE-----")
      assert String.contains?(decrypted.text_body, "-----END PGP MESSAGE-----")
    end

    test "stores PGP-signed email body", %{mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Signed Message",
        "plain_body" => @sample_pgp_signed_message,
        "html_body" => nil,
        "message_id" => "pgp-signed-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)

      decrypted = Email.Message.decrypt_content(message)
      assert String.contains?(decrypted.text_body, "-----BEGIN PGP SIGNED MESSAGE-----")
      assert String.contains?(decrypted.text_body, "-----BEGIN PGP SIGNATURE-----")
    end

    test "stores email with inline PGP content", %{mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Inline PGP",
        "plain_body" => @sample_pgp_inline_message,
        "html_body" => nil,
        "message_id" => "pgp-inline-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)

      decrypted = Email.Message.decrypt_content(message)
      assert String.contains?(decrypted.text_body, "Hello,")
      assert String.contains?(decrypted.text_body, "-----BEGIN PGP MESSAGE-----")
      assert String.contains?(decrypted.text_body, "Best regards,")
    end

    test "handles PGP message with special characters in subject", %{mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "[PGP] Encrypted: Test & Special <chars>",
        "plain_body" => @sample_pgp_message,
        "html_body" => nil,
        "message_id" => "pgp-special-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.subject == "[PGP] Encrypted: Test & Special <chars>"
    end

    test "stores email from PGP-enabled sender with key in header", %{mailbox: mailbox} do
      # Some email clients include the sender's public key in headers
      params = %{
        "from" => "pgpuser@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Message with key",
        "plain_body" => @sample_pgp_message,
        "html_body" => nil,
        "message_id" => "pgp-withkey-#{System.unique_integer([:positive])}@example.com",
        "headers" => %{
          "X-PGP-Key" =>
            "-----BEGIN PGP PUBLIC KEY BLOCK-----\ntest\n-----END PGP PUBLIC KEY BLOCK-----"
        }
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id
    end

    test "processes email with both encrypted body and attachments", %{mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Encrypted with attachment",
        "plain_body" => @sample_pgp_message,
        "html_body" => nil,
        "message_id" => "pgp-attach-#{System.unique_integer([:positive])}@example.com",
        "attachments" => [
          %{
            "filename" => "document.pdf.gpg",
            "content_type" => "application/pgp-encrypted",
            "size" => 1024,
            "data" => Base.encode64("encrypted content")
          }
        ]
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.has_attachments == true
      assert map_size(message.attachments) == 1
    end
  end

  describe "PGP content detection" do
    test "detects PGP encrypted message" do
      assert is_pgp_encrypted?(@sample_pgp_message)
    end

    test "detects PGP signed message" do
      assert is_pgp_signed?(@sample_pgp_signed_message)
    end

    test "detects inline PGP content" do
      assert has_pgp_content?(@sample_pgp_inline_message)
    end

    test "returns false for plain text" do
      refute is_pgp_encrypted?("Hello, this is a plain text message.")
    end

    test "returns false for nil" do
      refute is_pgp_encrypted?(nil)
    end

    test "returns false for empty string" do
      refute is_pgp_encrypted?("")
    end
  end

  describe "PGP/MIME messages" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "pgpmime#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      mailbox = Email.get_user_mailbox(user.id)

      %{user: user, mailbox: mailbox}
    end

    test "handles PGP/MIME encrypted message", %{mailbox: mailbox} do
      # PGP/MIME uses multipart/encrypted content type
      pgp_mime_body = """
      This is an OpenPGP/MIME encrypted message (RFC 4880 and 3156)
      """

      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "PGP/MIME Message",
        "plain_body" => pgp_mime_body,
        "html_body" => nil,
        "message_id" => "pgpmime-#{System.unique_integer([:positive])}@example.com",
        "headers" => %{
          "Content-Type" => "multipart/encrypted; protocol=\"application/pgp-encrypted\""
        }
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id
    end

    test "handles PGP/MIME signed message", %{mailbox: mailbox} do
      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "PGP/MIME Signed",
        "plain_body" => "This message is signed using PGP/MIME.",
        "html_body" => nil,
        "message_id" => "pgpmime-signed-#{System.unique_integer([:positive])}@example.com",
        "headers" => %{
          "Content-Type" =>
            "multipart/signed; protocol=\"application/pgp-signature\"; micalg=pgp-sha256"
        }
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id
    end
  end

  describe "edge cases" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "pgpedge#{System.unique_integer([:positive])}",
          password: "Test123456!",
          password_confirmation: "Test123456!"
        })

      mailbox = Email.get_user_mailbox(user.id)

      %{user: user, mailbox: mailbox}
    end

    test "handles malformed PGP armor gracefully", %{mailbox: mailbox} do
      malformed_pgp = """
      -----BEGIN PGP MESSAGE-----

      This is not valid base64!@#$%
      Missing checksum line

      -----END PGP MESSAGE-----
      """

      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Malformed PGP",
        "plain_body" => malformed_pgp,
        "html_body" => nil,
        "message_id" => "pgp-malformed-#{System.unique_integer([:positive])}@example.com"
      }

      # Should still store the message even if PGP is malformed
      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id
    end

    test "handles truncated PGP message", %{mailbox: mailbox} do
      truncated_pgp = """
      -----BEGIN PGP MESSAGE-----

      hQEMA1234567890ABCAQ/9H7B3c4V8mKTk2YpHvWpLKF6
      """

      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Truncated PGP",
        "plain_body" => truncated_pgp,
        "html_body" => nil,
        "message_id" => "pgp-truncated-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id
    end

    test "handles very long PGP message", %{mailbox: mailbox} do
      # Generate a long PGP-like message
      long_base64 =
        String.duplicate("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 1000)

      long_pgp = """
      -----BEGIN PGP MESSAGE-----

      #{long_base64}
      =ABCD
      -----END PGP MESSAGE-----
      """

      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Long PGP Message",
        "plain_body" => long_pgp,
        "html_body" => nil,
        "message_id" => "pgp-long-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)
      assert message.mailbox_id == mailbox.id
    end

    test "handles multiple PGP blocks in one email", %{mailbox: mailbox} do
      multi_pgp = """
      First encrypted block:

      -----BEGIN PGP MESSAGE-----

      hQEMA1234567890ABCAQ/block1
      =AAA1
      -----END PGP MESSAGE-----

      Second encrypted block:

      -----BEGIN PGP MESSAGE-----

      hQEMA1234567890ABCAQ/block2
      =BBB2
      -----END PGP MESSAGE-----
      """

      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "Multiple PGP Blocks",
        "plain_body" => multi_pgp,
        "html_body" => nil,
        "message_id" => "pgp-multi-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)

      decrypted = Email.Message.decrypt_content(message)
      # Both blocks should be preserved
      assert String.contains?(decrypted.text_body, "block1")
      assert String.contains?(decrypted.text_body, "block2")
    end

    test "handles PGP public key block in email body", %{mailbox: mailbox} do
      key_share = """
      Hi! Here's my PGP public key:

      -----BEGIN PGP PUBLIC KEY BLOCK-----

      mQENBGaT5OUBCAC3qKXrCXvWl5vNlRBNKPZNFAj3zLjXBdgOJvSqHHJwlHIbN1Gs
      =ABCD
      -----END PGP PUBLIC KEY BLOCK-----

      Please add me to your contacts!
      """

      params = %{
        "from" => "sender@example.com",
        "to" => mailbox.email,
        "rcpt_to" => mailbox.email,
        "subject" => "My PGP Key",
        "plain_body" => key_share,
        "html_body" => nil,
        "message_id" => "pgp-keyshare-#{System.unique_integer([:positive])}@example.com"
      }

      assert {:ok, message} = Receiver.process_incoming_email(params)

      decrypted = Email.Message.decrypt_content(message)
      assert String.contains?(decrypted.text_body, "-----BEGIN PGP PUBLIC KEY BLOCK-----")
    end
  end

  # Helper functions for PGP content detection
  defp is_pgp_encrypted?(nil), do: false
  defp is_pgp_encrypted?(""), do: false

  defp is_pgp_encrypted?(text) when is_binary(text) do
    String.contains?(text, "-----BEGIN PGP MESSAGE-----") and
      String.contains?(text, "-----END PGP MESSAGE-----")
  end

  defp is_pgp_signed?(nil), do: false
  defp is_pgp_signed?(""), do: false

  defp is_pgp_signed?(text) when is_binary(text) do
    String.contains?(text, "-----BEGIN PGP SIGNED MESSAGE-----") or
      (String.contains?(text, "-----BEGIN PGP SIGNATURE-----") and
         String.contains?(text, "-----END PGP SIGNATURE-----"))
  end

  defp has_pgp_content?(text) when is_binary(text) and text != "" do
    is_pgp_encrypted?(text) or is_pgp_signed?(text) or
      String.contains?(text, "-----BEGIN PGP PUBLIC KEY BLOCK-----")
  end

  defp has_pgp_content?(_), do: false
end
