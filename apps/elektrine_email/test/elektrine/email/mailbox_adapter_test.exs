defmodule Elektrine.Email.MailboxAdapterTest do
  use Elektrine.DataCase, async: true

  import ExUnit.CaptureLog

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.Email.MailboxAdapter

  test "routing validation failure logs redact message attributes" do
    user = AccountsFixtures.user_fixture()

    mailbox =
      Email.get_user_mailbox(user.id) ||
        case Email.ensure_user_has_mailbox(user) do
          {:ok, mailbox} -> mailbox
          mailbox -> mailbox
        end

    attrs = %{
      mailbox_id: mailbox.id,
      from: "sender@example.net",
      to: "wrong-recipient@example.net",
      subject: "Sensitive subject",
      text_body: "Sensitive plaintext body",
      html_body: "<p>Sensitive HTML body</p>",
      attachments: %{
        "0" => %{
          "filename" => "secret.txt",
          "content_type" => "text/plain",
          "data" => Base.encode64("secret attachment payload")
        }
      }
    }

    log =
      capture_log(fn ->
        assert {:error, :final_routing_validation_failed} = MailboxAdapter.create_message(attrs)
      end)

    assert log =~ "FINAL ROUTING VALIDATION FAILED"
    assert log =~ "Routing metadata:"
    assert log =~ "[redacted-email]"
    refute log =~ "Sensitive subject"
    refute log =~ "Sensitive plaintext body"
    refute log =~ "Sensitive HTML body"
    refute log =~ "secret attachment payload"
    refute log =~ "wrong-recipient@example.net"
  end
end
