defmodule Elektrine.Email.SenderValidationTest do
  @moduledoc """
  Tests for email recipient validation to ensure emails cannot be sent without valid recipients.
  """

  use Elektrine.DataCase
  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.Sender

  describe "recipient validation" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "sendertest",
          password: "SenderTest123!",
          password_confirmation: "SenderTest123!"
        })

      {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
      %{user: user, mailbox: mailbox}
    end

    test "rejects emails with no recipients", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "",
        cc: "",
        bcc: "",
        subject: "Test Email",
        text_body: "This should be rejected"
      }

      {:error, reason} = Sender.send_email(user.id, email_params)
      assert reason == "At least one valid recipient is required (To, CC, or BCC)"
    end

    test "rejects emails with only whitespace recipients", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "   ",
        cc: " ",
        bcc: "",
        subject: "Test Email",
        text_body: "This should be rejected"
      }

      {:error, reason} = Sender.send_email(user.id, email_params)
      assert reason == "At least one valid recipient is required (To, CC, or BCC)"
    end

    test "rejects emails with invalid email formats", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "invalid-email",
        cc: "",
        bcc: "",
        subject: "Test Email",
        text_body: "This should be rejected"
      }

      {:error, reason} = Sender.send_email(user.id, email_params)
      assert reason == "At least one valid recipient is required (To, CC, or BCC)"
    end

    test "rejects emails with suspicious content in recipients", %{user: user, mailbox: mailbox} do
      suspicious_emails = [
        "test@example.com<script>alert('xss')</script>",
        "test@example.com<iframe>",
        "javascript:alert('xss')@example.com",
        "test;rm -rf /@example.com"
      ]

      for suspicious_email <- suspicious_emails do
        email_params = %{
          from: mailbox.email,
          to: suspicious_email,
          cc: "",
          bcc: "",
          subject: "Test Email",
          text_body: "This should be rejected"
        }

        {:error, reason} = Sender.send_email(user.id, email_params)
        assert reason == "Invalid recipient address detected"
      end
    end

    test "accepts emails with valid recipients in to field", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "valid@example.com",
        cc: "",
        bcc: "",
        subject: "Test Email",
        text_body: "This should work"
      }

      # Note: This will fail with external email sending, but should pass recipient validation
      result = Sender.send_email(user.id, email_params)
      # The error should not be about recipients
      case result do
        {:error, "At least one valid recipient is required (To, CC, or BCC)"} ->
          flunk("Recipient validation failed for valid email")

        {:error, "Invalid recipient address detected"} ->
          flunk("Valid recipient was flagged as suspicious")

        _ ->
          # Other errors are acceptable (like external sending failures)
          :ok
      end
    end

    test "accepts emails with valid recipients in cc field only", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "",
        cc: "valid@example.com",
        bcc: "",
        subject: "Test Email",
        text_body: "This should work"
      }

      result = Sender.send_email(user.id, email_params)
      # Should not fail on recipient validation
      case result do
        {:error, "At least one valid recipient is required (To, CC, or BCC)"} ->
          flunk("Recipient validation failed for valid CC")

        {:error, "Invalid recipient address detected"} ->
          flunk("Valid CC recipient was flagged as suspicious")

        _ ->
          :ok
      end
    end

    test "accepts emails with valid recipients in bcc field only", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "",
        cc: "",
        bcc: "valid@example.com",
        subject: "Test Email",
        text_body: "This should work"
      }

      result = Sender.send_email(user.id, email_params)
      # Should not fail on recipient validation
      case result do
        {:error, "At least one valid recipient is required (To, CC, or BCC)"} ->
          flunk("Recipient validation failed for valid BCC")

        {:error, "Invalid recipient address detected"} ->
          flunk("Valid BCC recipient was flagged as suspicious")

        _ ->
          :ok
      end
    end

    test "accepts emails with multiple valid recipients", %{user: user, mailbox: mailbox} do
      email_params = %{
        from: mailbox.email,
        to: "user1@example.com, user2@example.com",
        cc: "cc@example.com",
        bcc: "bcc@example.com",
        subject: "Test Email",
        text_body: "This should work"
      }

      result = Sender.send_email(user.id, email_params)
      # Should not fail on recipient validation
      case result do
        {:error, "At least one valid recipient is required (To, CC, or BCC)"} ->
          flunk("Recipient validation failed for multiple valid emails")

        {:error, "Invalid recipient address detected"} ->
          flunk("Valid recipients were flagged as suspicious")

        _ ->
          :ok
      end
    end
  end
end
