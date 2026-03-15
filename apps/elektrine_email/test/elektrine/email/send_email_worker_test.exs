defmodule Elektrine.Email.SendEmailWorkerTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.Email.SendEmailWorker
  alias Elektrine.JMAP
  alias Oban.Job

  test "finalizes a submission after a worker-delivered send" do
    user = AccountsFixtures.user_fixture()
    recipient = AccountsFixtures.user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient)

    {:ok, draft} =
      Email.create_message(%{
        from: mailbox.email,
        to: recipient_mailbox.email,
        subject: "Worker finalized submission",
        text_body: "scheduled path body",
        status: "draft",
        message_id: "<worker-submission-#{System.unique_integer([:positive])}@example.com>",
        mailbox_id: mailbox.id
      })

    send_at = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

    {:ok, submission} =
      JMAP.create_submission(%{
        mailbox_id: mailbox.id,
        email_id: draft.id,
        identity_id: "identity-#{user.id}",
        envelope_from: mailbox.email,
        envelope_to: [recipient_mailbox.email],
        send_at: send_at,
        undo_status: "pending",
        delivery_status: %{
          "status" => "scheduled",
          "scheduledAt" => DateTime.to_iso8601(send_at)
        }
      })

    assert :ok =
             SendEmailWorker.perform(%Job{
               args: %{
                 "user_id" => user.id,
                 "submission_id" => submission.id,
                 "email_attrs" => %{
                   "from" => mailbox.email,
                   "to" => recipient_mailbox.email,
                   "subject" => "Worker finalized submission",
                   "text_body" => "scheduled path body"
                 }
               }
             })

    updated_submission = JMAP.get_submission(submission.id, mailbox.id)
    recipient_messages = Email.list_messages(recipient_mailbox.id, 50, 0)

    assert updated_submission.undo_status == "final"
    assert updated_submission.delivery_status["status"] == "sent"
    assert Enum.any?(recipient_messages, &(&1.subject == "Worker finalized submission"))
  end
end
