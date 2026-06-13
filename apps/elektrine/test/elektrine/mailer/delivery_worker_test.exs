defmodule Elektrine.Mailer.DeliveryWorkerTest do
  use Elektrine.DataCase, async: false

  import Swoosh.Email, except: [from: 2]

  test "deliver_later delivers the email through the Oban worker" do
    email =
      new()
      |> Swoosh.Email.from({"Elektrine", "noreply@example.com"})
      |> to({"someone", "someone@example.com"})
      |> cc("copy@example.com")
      |> reply_to("replies@example.com")
      |> subject("Hello from the queue")
      |> text_body("plain text")
      |> html_body("<p>html</p>")
      |> header("List-Id", "<elektrine-account.example.com>")

    assert {:ok, _job} = Elektrine.Mailer.deliver_later(email)

    # Oban runs inline in test, so the Swoosh test adapter has already
    # delivered the rebuilt email to this process.
    assert_receive {:email, %Swoosh.Email{} = delivered}

    assert delivered.from == {"Elektrine", "noreply@example.com"}
    assert delivered.to == [{"someone", "someone@example.com"}]
    assert delivered.cc == [{"", "copy@example.com"}]
    assert delivered.reply_to == {"", "replies@example.com"}
    assert delivered.subject == "Hello from the queue"
    assert delivered.text_body == "plain text"
    assert delivered.html_body == "<p>html</p>"
    assert delivered.headers == %{"List-Id" => "<elektrine-account.example.com>"}
  end

  test "deliver_later rejects emails with attachments" do
    email =
      new()
      |> Swoosh.Email.from("noreply@example.com")
      |> to("someone@example.com")
      |> subject("with attachment")
      |> text_body("body")
      |> attachment(%Swoosh.Attachment{
        filename: "file.txt",
        content_type: "text/plain",
        data: "contents"
      })

    assert_raise ArgumentError, fn -> Elektrine.Mailer.deliver_later(email) end
  end
end
