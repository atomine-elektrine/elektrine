defmodule ElektrineEmailWeb.EmailLive.ShowThreadContextTest do
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

  defp thread_fixture(user) do
    mailbox = mailbox_for(user)
    root_message_id = "<thread-root-#{System.unique_integer([:positive])}@example.com>"
    reply_message_id = "<thread-reply-#{System.unique_integer([:positive])}@example.com>"

    {:ok, original} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "Nick Liu <nick@example.com>",
        to: mailbox.email,
        subject: "elektrine",
        text_body: "Please kindly send your CEO this email",
        message_id: root_message_id,
        status: "received"
      })

    {:ok, reply} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: mailbox.email,
        to: "Nick Liu <nick@example.com>",
        subject: "Re: elektrine",
        text_body: "elektrine.com has no relation at all to Baoming Ltd.",
        message_id: reply_message_id,
        in_reply_to: root_message_id,
        status: "sent"
      })

    original = Email.get_message(original.id, mailbox.id)
    {original, reply}
  end

  test "opening a sent reply by hash shows the reply, not the original", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {original, reply} = thread_fixture(user)

    assert reply.thread_id == original.thread_id

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{reply.hash}?return_to=sent")

    # The reading pane must render the sent reply.
    assert html =~ "email-iframe-#{reply.id}"
    refute html =~ "email-iframe-#{original.id}"

    # The Conversation Context must highlight the sent reply as current, so
    # the current row is a div (not a link) containing the reply preview.
    assert has_element?(view, "div.border-secondary", "no relation at all to Baoming")
    refute has_element?(view, "div.border-secondary", "Please kindly send")

    # The original is still reachable as a link in the context panel.
    assert has_element?(view, "a[href*='#{original.hash}']")
  end

  test "a reply sent through the real pipeline opens as itself from Sent", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = mailbox_for(user)
    {:ok, _} = Atomine.Credits.grant(user.id, :atomine_credit, 10, "test_grant")

    root_message_id = "<pipeline-root-#{System.unique_integer([:positive])}@example.com>"

    {:ok, original} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "Nick Liu <nick@external-example.com>",
        to: mailbox.email,
        subject: "elektrine",
        text_body: "Please kindly send your CEO this email",
        message_id: root_message_id,
        status: "received"
      })

    assert {:ok, _result} =
             Elektrine.Email.Sender.send_email(user.id, %{
               from: mailbox.email,
               to: "nick@external-example.com",
               subject: "Re: elektrine",
               text_body: "elektrine.com has no relation at all to Baoming Ltd.",
               html_body: "<p>elektrine.com has no relation at all to Baoming Ltd.</p>",
               in_reply_to: root_message_id
             })

    original = Email.get_message(original.id, mailbox.id)

    sent_copy =
      Elektrine.Repo.get_by!(Elektrine.Email.Message, mailbox_id: mailbox.id, status: "sent")

    assert sent_copy.thread_id == original.thread_id

    # The Sent tab lists the sent copy as the thread head.
    %{messages: [sent_row]} = Email.list_sent_messages_paginated(mailbox.id)
    assert sent_row.id == sent_copy.id

    conn = log_in_user(conn, user)

    {:ok, view, html} = live(conn, ~p"/email/view/#{sent_row.hash || sent_row.id}?return_to=sent")

    assert html =~ "email-iframe-#{sent_copy.id}"
    refute html =~ "email-iframe-#{original.id}"
    assert has_element?(view, "div.border-secondary", "no relation at all to Baoming")
    refute has_element?(view, "div.border-secondary", "Please kindly send")
  end

  test "replying to a full-document HTML email keeps the typed reply visible", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = mailbox_for(user)
    {:ok, _} = Atomine.Credits.grant(user.id, :atomine_credit, 10, "test_grant")

    scam_html = """
    <html><head><style>body { font-family: Arial; }</style></head>
    <body><table width="100%"><tr><td>
    <p>(Please Kindly send this email to your CEO because this is urgent.)</p>
    </td></tr></table></body></html>
    """

    {:ok, original} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "Nick Liu <nick@chinanetdomains.com>",
        to: mailbox.email,
        subject: "elektrine",
        text_body: "(Please Kindly send this email to your CEO because this is urgent.)",
        html_body: scam_html,
        message_id: "<scam-#{System.unique_integer([:positive])}@chinanetdomains.com>",
        status: "received"
      })

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/email/compose?mode=reply&message_id=#{original.id}")

    reply_text = "elektrine.com has no relation at all to Baoming Ltd."

    quoted_body =
      "\n\nOn Thu, Jul 16, 2026, \"Nick Liu\" <nick@chinanetdomains.com> wrote:\n> (Please Kindly send this email to your CEO because this is urgent.)"

    render_submit(view, "save", %{
      "email" => %{
        "new_message" => reply_text,
        "body" => quoted_body,
        "subject" => "Re: elektrine"
      }
    })

    sent_copy =
      Elektrine.Repo.get_by!(Elektrine.Email.Message, mailbox_id: mailbox.id, status: "sent")
      |> Elektrine.Email.Message.decrypt_content(user.id)

    assert sent_copy.text_body =~ reply_text
    assert sent_copy.html_body =~ reply_text

    # The rendered iframe body must contain the typed reply before the quote.
    iframe_conn = get(conn, ~p"/email/#{sent_copy.id}/iframe_content")
    body = response(iframe_conn, 200)
    assert body =~ reply_text

    {reply_idx, _} = :binary.match(body, reply_text)
    {quote_idx, _} = :binary.match(body, "Kindly send this email")
    assert reply_idx < quote_idx
  end

  test "clicking the sent reply row in context navigates to the reply", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {original, reply} = thread_fixture(user)

    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/email/view/#{original.hash}")

    # The context panel links to the sent reply by its own identifier.
    assert has_element?(view, "a[href*='#{reply.hash}']")

    {:ok, _reply_view, reply_html} =
      view
      |> element("a[href*='#{reply.hash}']")
      |> render_click()
      |> follow_redirect(conn)

    assert reply_html =~ "email-iframe-#{reply.id}"
    refute reply_html =~ "email-iframe-#{original.id}"
  end
end
