defmodule Elektrine.IMAP.ResponseSecurityTest do
  use ExUnit.Case, async: true

  alias Elektrine.IMAP.Response

  test "generated RFC822 attachment headers sanitize filename, content type, and content id" do
    message =
      message_with_attachment(%{
        "filename" => "report\"\r\nX-Evil: yes.pdf",
        "content_type" => "text/plain\r\nX-Evil: yes",
        "content_id" => "logo>\r\nX-Evil: yes",
        "data" => Base.encode64("hello")
      })

    rfc822 = Response.build_rfc822_message(message)

    refute rfc822 =~ "\r\nX-Evil:"
    assert rfc822 =~ ~s(Content-Type: application/octet-stream; name="report___X-Evil: yes.pdf")
    assert rfc822 =~ ~s(Content-Disposition: inline; filename="report___X-Evil: yes.pdf")
    assert rfc822 =~ "Content-ID: <logoX-Evil: yes>"
  end

  test "BODYSTRUCTURE escapes attachment filenames as IMAP quoted strings" do
    message =
      message_with_attachment(%{
        "filename" => "report\") NIL (\"TEXT\" \"PLAIN\"\r\nX-Evil: yes.pdf",
        "content_type" => "application/pdf",
        "data" => Base.encode64("hello")
      })

    bodystructure = Response.build_bodystructure(message)

    refute bodystructure =~ "\r\nX-Evil:"
    refute bodystructure =~ "\") NIL (\"TEXT\" \"PLAIN\""
    assert bodystructure =~ ~S|"NAME" "report_) NIL (_TEXT_ _PLAIN___X-Evil: yes.pdf"|
  end

  test "generated RFC822 top-level headers collapse control characters" do
    message =
      base_message(%{
        subject: "Hello\r\nX-Evil: yes",
        from: "sender@example.com\r\nBcc: victim@example.com",
        text_body: "body"
      })

    rfc822 = Response.build_rfc822_message(message)

    refute rfc822 =~ "\r\nX-Evil:"
    refute rfc822 =~ "\r\nBcc:"
    assert rfc822 =~ "Subject: Hello  X-Evil: yes\r\n"
    assert rfc822 =~ "From: sender@example.com  Bcc: victim@example.com\r\n"
  end

  test "IMAP address tuples escape quoted-string metacharacters and controls" do
    address = ~s|"Eve\r\nX-Evil: yes" <local") NIL ("TEXT"@example.com>|

    parsed = Response.parse_address(address)

    refute parsed =~ "\r\nX-Evil:"
    refute parsed =~ "\") NIL (\"TEXT\""
    assert parsed =~ ~s|"local\\") NIL (\\\"TEXT\\\"" "example.com"|
  end

  defp message_with_attachment(attachment) do
    base_message(%{
      has_attachments: true,
      attachments: %{"1" => attachment},
      text_body: "body"
    })
  end

  defp base_message(attrs) do
    Map.merge(
      %{
        from: "sender@example.com",
        to: "recipient@example.com",
        subject: "Subject",
        message_id: "message@example.com",
        inserted_at: ~U[2026-06-24 00:00:00Z],
        text_body: nil,
        html_body: nil,
        has_attachments: false,
        attachments: %{}
      },
      attrs
    )
  end
end
