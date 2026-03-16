defmodule Elektrine.Email.AutoRepliesTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Swoosh.TestAssertions

  alias Elektrine.Email
  alias Elektrine.Email.AutoReplies

  setup :set_swoosh_global

  test "reply-once tracking normalizes display-name sender variants" do
    user = user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    assert {:ok, _auto_reply} =
             AutoReplies.upsert_auto_reply(user.id, %{
               enabled: true,
               body: "Away from keyboard"
             })

    assert {:ok, first_message} =
             Email.create_message(%{
               from: "Jane Sender <jane@example.com>",
               to: mailbox.email,
               subject: "Checking in",
               text_body: "hello",
               message_id: "<auto-reply-first-#{System.unique_integer([:positive])}@example.com>",
               mailbox_id: mailbox.id,
               status: "received"
             })

    assert :sent = AutoReplies.process_auto_reply(first_message, user.id)
    assert_email_sent(to: "jane@example.com", subject: "Re: Checking in")
    assert AutoReplies.has_replied_to?(user.id, "jane@example.com")

    assert {:ok, second_message} =
             Email.create_message(%{
               from: "jane@example.com",
               to: mailbox.email,
               subject: "Following up",
               text_body: "ping",
               message_id:
                 "<auto-reply-second-#{System.unique_integer([:positive])}@example.com>",
               mailbox_id: mailbox.id,
               status: "received"
             })

    assert :skip = AutoReplies.process_auto_reply(second_message, user.id)
    refute_email_sent()
  end
end
