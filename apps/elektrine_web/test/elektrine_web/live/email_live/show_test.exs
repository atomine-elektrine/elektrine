defmodule ElektrineEmailWeb.EmailLive.ShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.{Email, Notifications}

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

  defp portal_nav_badges(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(nav.e-nav a[href="/portal"] span.absolute))
    |> Enum.map(&(Floki.text(&1) |> String.trim()))
  end

  test "deleting from a custom folder returns to that folder", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)
    {:ok, folder} = Email.create_custom_folder(%{user_id: user.id, name: "Receipts"})

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Folder redirect regression",
        text_body: "Move me to trash",
        html_body: "<p>Move me to trash</p>",
        folder_id: folder.id,
        message_id: "<folder-delete-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}?return_to=folder&folder_id=#{folder.id}")

    view
    |> element("button[phx-click='delete'][phx-value-id='#{message.id}']")
    |> render_click()

    assert_redirect(view, ~p"/email?tab=folder&folder_id=#{folder.id}")
  end

  test "opening an unread email clears the portal nav bubble", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Portal badge refresh regression",
        text_body: "Mark this read",
        html_body: "<p>Mark this read</p>",
        message_id: "<portal-badge-#{System.unique_integer([:positive])}@example.com>"
      })

    assert Notifications.get_unread_count(user.id) == 1

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}")

    assert Notifications.get_unread_count(user.id) == 0
    assert portal_nav_badges(html) == []
  end

  test "email content iframe keeps same-origin access for proxied images without scripts", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Iframe sandbox regression",
        html_body: ~s(<p><img src="https://example.com/image.png"></p>),
        message_id: "<iframe-sandbox-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}")

    document = Floki.parse_document!(html)

    [sandbox] =
      document
      |> Floki.find("iframe.email-content-iframe")
      |> Floki.attribute("sandbox")

    assert sandbox =~ "allow-same-origin"
    refute sandbox =~ "allow-scripts"
  end

  test "forged message action ids do not crash the show view", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Malformed action ids",
        text_body: "Keep this view alive",
        html_body: "<p>Keep this view alive</p>",
        message_id: "<malformed-action-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, delete_view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}")

    render_hook(delete_view, "delete", %{"id" => "12abc"})
    assert_redirect(delete_view, ~p"/email?tab=inbox")

    {:ok, recover_view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}")

    render_hook(recover_view, "recover", %{"id" => "12abc"})
    assert_redirect(recover_view, ~p"/email?tab=inbox")
  end

  test "forged reply later days do not crash the show view", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Malformed reply later days",
        text_body: "Schedule me later",
        html_body: "<p>Schedule me later</p>",
        message_id: "<malformed-reply-later-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}")

    assert render_hook(view, "schedule_reply_later", %{"days" => "abc"}) =~
             "Invalid reply later interval"
  end

  defp ensure_mailbox(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end
end
