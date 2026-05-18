defmodule Elektrine.Email.SenderRateLimitTest do
  use Elektrine.DataCase

  import Swoosh.TestAssertions

  alias Atomine.Credits
  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Sender

  setup :set_swoosh_global

  describe "TL0 sender limits" do
    setup do
      {:ok, sender} =
        Accounts.create_user(%{
          username: "senderlimit#{System.unique_integer([:positive])}",
          password: "SenderLimit123!",
          password_confirmation: "SenderLimit123!"
        })

      {:ok, sender_mailbox} = Email.ensure_user_has_mailbox(sender)

      RateLimiter.clear_limits(sender.id)

      %{sender: sender, sender_mailbox: sender_mailbox}
    end

    test "blocks an immediate second send for TL0 users", %{
      sender: sender,
      sender_mailbox: sender_mailbox
    } do
      assert {:ok, _ledger_entry} = Credits.grant(sender.id, :atomine_credit, 1, "test_grant")

      params = %{
        from: sender_mailbox.email,
        to: "reader@example.com",
        subject: "First send",
        text_body: "hello"
      }

      assert {:ok, _sent_message} = Sender.send_email(sender.id, params)

      assert {:error, :rate_limit_exceeded} =
               Sender.send_email(sender.id, %{params | subject: "Second send"})
    end
  end
end
