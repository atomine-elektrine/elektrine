defmodule Elektrine.Email.SenderRateLimitTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Sender

  describe "TL0 sender limits" do
    setup do
      {:ok, sender} =
        Accounts.create_user(%{
          username: "senderlimit#{System.unique_integer([:positive])}",
          password: "SenderLimit123!",
          password_confirmation: "SenderLimit123!"
        })

      {:ok, recipient} =
        Accounts.create_user(%{
          username: "recipientlimit#{System.unique_integer([:positive])}",
          password: "RecipientLimit123!",
          password_confirmation: "RecipientLimit123!"
        })

      {:ok, sender_mailbox} = Email.ensure_user_has_mailbox(sender)
      {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient)

      RateLimiter.clear_limits(sender.id)

      %{sender: sender, sender_mailbox: sender_mailbox, recipient_mailbox: recipient_mailbox}
    end

    test "blocks a second send in the same day for TL0 users", %{
      sender: sender,
      sender_mailbox: sender_mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      params = %{
        from: sender_mailbox.email,
        to: recipient_mailbox.email,
        subject: "First send",
        text_body: "hello"
      }

      assert {:ok, _sent_message} = Sender.send_email(sender.id, params)

      assert {:error, :rate_limit_exceeded} =
               Sender.send_email(sender.id, %{params | subject: "Second send"})
    end
  end
end
