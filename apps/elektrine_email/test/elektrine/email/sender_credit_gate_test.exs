defmodule Elektrine.Email.SenderCreditGateTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Swoosh.TestAssertions

  alias Atomine.Credits
  alias Elektrine.Accounts.User
  alias Elektrine.Email
  alias Elektrine.Email.RateLimiter
  alias Elektrine.Email.Sender
  alias Elektrine.Repo

  setup :set_swoosh_global

  setup do
    previous_config = Application.get_env(:atomine, :credits, [])

    Application.put_env(
      :atomine,
      :credits,
      Keyword.put(previous_config, :email_gate_enabled, true)
    )

    sender = user_fixture()
    recipient = user_fixture()
    {:ok, sender_mailbox} = Email.ensure_user_has_mailbox(sender)
    {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient)
    RateLimiter.clear_limits(sender.id)

    on_exit(fn ->
      Application.put_env(:atomine, :credits, previous_config)
      RateLimiter.clear_limits(sender.id)
    end)

    %{
      sender: sender,
      recipient_mailbox: recipient_mailbox,
      sender_mailbox: sender_mailbox
    }
  end

  test "TL0 users need Atomine Credits for external sends", %{
    sender: sender,
    sender_mailbox: sender_mailbox
  } do
    assert {:error, :insufficient_email_credits} =
             Sender.send_email(sender.id, external_params(sender_mailbox.email))

    refute_received {:email, _email}
  end

  test "spends Atomine Credits for external sends", %{
    sender: sender,
    sender_mailbox: sender_mailbox
  } do
    assert {:ok, _ledger_entry} = Credits.grant(sender.id, :atomine_credit, 1, "test_grant")

    assert {:ok, %{status: "queued"}} =
             Sender.send_email(sender.id, external_params(sender_mailbox.email))

    assert_received {:email, _email}
    assert Credits.balance(sender.id, :atomine_credit) == 0
  end

  test "internal sends do not require Atomine Credits", %{
    sender: sender,
    recipient_mailbox: recipient_mailbox,
    sender_mailbox: sender_mailbox
  } do
    assert {:ok, sent_message} =
             Sender.send_email(sender.id, %{
               from: sender_mailbox.email,
               to: recipient_mailbox.email,
               subject: "Internal hello",
               text_body: "hello"
             })

    assert sent_message.status == "sent"
    assert Credits.balance(sender.id, :atomine_credit) == 0
  end

  test "TL3 users can send external email without Atomine Credits", %{
    sender: sender,
    sender_mailbox: sender_mailbox
  } do
    sender = promote_to_trust_level(sender, 3)

    assert {:ok, %{status: "queued"}} =
             Sender.send_email(sender.id, external_params(sender_mailbox.email))

    assert_received {:email, _email}
    assert Credits.balance(sender.id, :atomine_credit) == 0
  end

  test "admins can send external email without Atomine Credits", %{
    sender: sender,
    sender_mailbox: sender_mailbox
  } do
    sender = promote_to_admin(sender)

    assert {:ok, %{status: "queued"}} =
             Sender.send_email(sender.id, external_params(sender_mailbox.email))

    assert_received {:email, _email}
    assert Credits.balance(sender.id, :atomine_credit) == 0
  end

  defp external_params(from) do
    %{
      from: from,
      to: "reader@example.com",
      subject: "External hello",
      text_body: "hello"
    }
  end

  defp promote_to_trust_level(%User{} = user, trust_level) do
    user
    |> User.trust_level_changeset(%{trust_level: trust_level})
    |> Repo.update!()
  end

  defp promote_to_admin(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{is_admin: true})
    |> Repo.update!()
  end
end
