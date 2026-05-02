defmodule Elektrine.Accounts.StorageTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Accounts.Storage
  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.EmailFixtures

  describe "email storage" do
    test "separates message content from attachment bytes" do
      user = AccountsFixtures.user_fixture()
      mailbox = Email.get_user_mailbox(user.id)
      message_storage_before = Storage.calculate_email_message_storage(user.id)
      attachment_storage_before = Storage.calculate_email_attachment_storage(user.id)

      EmailFixtures.message_fixture(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        cc: "cc@example.com",
        bcc: "bcc@example.com",
        subject: "Subject",
        text_body: "plain",
        html_body: "<p>html</p>",
        attachments: %{
          "0" => %{"filename" => "a.txt", "size" => 10},
          "1" => %{"filename" => "b.txt", "size" => "20"},
          "2" => %{"filename" => "bad.txt", "size" => "unknown"}
        }
      })

      message_delta = Storage.calculate_email_message_storage(user.id) - message_storage_before

      attachment_delta =
        Storage.calculate_email_attachment_storage(user.id) - attachment_storage_before

      assert message_delta > 0
      assert attachment_delta == 30

      assert Storage.calculate_email_storage(user.id) ==
               message_storage_before + attachment_storage_before + message_delta +
                 attachment_delta
    end
  end
end
