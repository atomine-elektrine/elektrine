defmodule ElektrineWeb.EmailComposeLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.EmailFixtures

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "reply body survives compose form changes", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)

    original =
      EmailFixtures.message_fixture(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Question",
        text_body: "Original question",
        html_body: "<p>Original question</p>"
      })

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/compose?mode=reply&message_id=#{original.id}")

    typed_reply = "This is the reply I typed."
    quoted_body = hidden_body_value(html)

    html =
      view
      |> form("#compose-form", %{
        "email" => %{
          "to" => "sender@example.com",
          "subject" => "Re: Question",
          "body" => quoted_body,
          "new_message" => typed_reply,
          "body_format" => "markdown",
          "encryption_mode" => "auto"
        }
      })
      |> render_change()

    assert html =~ typed_reply
  end

  defp hidden_body_value(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#full-message-body")
    |> Floki.attribute("value")
    |> List.first()
  end
end
