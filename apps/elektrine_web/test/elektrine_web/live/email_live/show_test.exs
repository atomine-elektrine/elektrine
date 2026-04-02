defmodule ElektrineWeb.EmailLive.ShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
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

  defp ensure_mailbox(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end
end
