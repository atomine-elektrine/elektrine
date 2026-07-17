defmodule ElektrineEmailWeb.ComposeParagraphSpacingTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email

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

  defp mailbox_for(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end

  @body "Good morning,\r\n\r\nThank you for contacting Elektrine.\r\n\r\nlegal@elektrine.com\r\n\r\nPlease include the full name."

  test "sending a new email keeps paragraph spacing in the stored copy", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = mailbox_for(user)
    {:ok, _} = Atomine.Credits.grant(user.id, :atomine_credit, 10, "test_grant")

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/email/compose?to=someone@example.com")

    render_submit(view, "save", %{
      "email" => %{
        "to" => "someone@example.com",
        "subject" => "spacing check",
        "body" => @body,
        "body_format" => "markdown"
      }
    })

    sent =
      Elektrine.Repo.get_by!(Elektrine.Email.Message, mailbox_id: mailbox.id, status: "sent")
      |> Elektrine.Email.Message.decrypt_content(user.id)

    # Plain-text alternative keeps its blank lines.
    assert sent.text_body =~ "Good morning,\r\n\r\nThank you"

    # Each paragraph is a distinct block with explicit vertical spacing, so mail
    # clients that zero default <p> margins still render gaps between paragraphs.
    assert sent.html_body =~ ~s(<p style="margin:0 0 1em 0;">Good morning,</p>)

    assert sent.html_body =~
             ~s(<p style="margin:0 0 1em 0;">Thank you for contacting Elektrine.</p>)

    assert length(String.split(sent.html_body, "<p style=")) == 5
  end
end
