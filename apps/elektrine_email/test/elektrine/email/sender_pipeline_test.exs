defmodule Elektrine.Email.SenderPipelineTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.Sender

  describe "outbound pipeline boundaries" do
    setup do
      sender_username = unique_username("sender")
      recipient_username = unique_username("recipient")

      {:ok, sender} =
        Accounts.create_user(%{
          username: sender_username,
          password: "SenderPipeline123!",
          password_confirmation: "SenderPipeline123!"
        })

      {:ok, recipient} =
        Accounts.create_user(%{
          username: recipient_username,
          password: "RecipientPipeline123!",
          password_confirmation: "RecipientPipeline123!"
        })

      {:ok, sender_mailbox} = Email.ensure_user_has_mailbox(sender)
      {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient)

      %{
        sender: sender,
        sender_mailbox: sender_mailbox,
        recipient_mailbox: recipient_mailbox
      }
    end

    test "parses raw SMTP data then sanitizes subject/body once", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      raw_email =
        [
          "From: #{sender_mailbox.email}",
          "To: #{recipient_mailbox.email}",
          "Subject: Hello",
          "\tBcc: attacker@example.com",
          "MIME-Version: 1.0",
          "Content-Type: text/html; charset=UTF-8",
          "",
          "<script>alert('x')</script><p>Hello</p>"
        ]
        |> Enum.join("\r\n")

      params = %{
        from: sender_mailbox.email,
        to: recipient_mailbox.email,
        raw_email: raw_email
      }

      assert {:ok, sent_message} = Sender.send_email(sender.id, params)
      refute sent_message.subject =~ ~r/bcc:/i

      sanitized_body = sent_message.html_body || sent_message.text_body || ""
      refute sanitized_body =~ "<script"
      assert sanitized_body =~ "Hello"
    end

    test "filters suppressed external recipients before routing", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      assert {:ok, _suppression} =
               Email.suppress_recipient(sender.id, "blocked@example.com",
                 reason: "hard_bounce",
                 source: "test"
               )

      params = %{
        from: sender_mailbox.email,
        to: "#{recipient_mailbox.email}, blocked@example.com",
        subject: "Suppression filter",
        text_body: "hello"
      }

      assert {:ok, sent_message} = Sender.send_email(sender.id, params)
      assert sent_message.to == recipient_mailbox.email
      refute String.contains?(sent_message.to, "blocked@example.com")
    end

    test "blocks send when every recipient is suppressed", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      assert {:ok, _suppression} =
               Email.suppress_recipient(sender.id, "blocked@example.com",
                 reason: "complaint",
                 source: "test"
               )

      params = %{
        from: sender_mailbox.email,
        to: "blocked@example.com",
        subject: "Suppressed only",
        text_body: "hello"
      }

      assert {:error, reason} = Sender.send_email(sender.id, params)
      assert reason =~ "suppressed"
    end
  end

  defp unique_username(prefix) do
    "#{prefix}#{System.unique_integer([:positive])}"
  end
end
