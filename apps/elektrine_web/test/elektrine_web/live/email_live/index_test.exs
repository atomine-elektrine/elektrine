defmodule ElektrineWeb.EmailLive.IndexTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.Repo
  alias ElektrineWeb.EmailLive.Index

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/email")
  end

  test "mount redirects when current_user assign is missing" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        flash: %{},
        __changed__: %{active_announcements: true},
        live_action: nil,
        active_announcements: []
      }
    }

    assert {:ok, mounted_socket} = Index.mount(%{}, %{}, socket)
    assert inspect(mounted_socket.redirected) =~ "/login"
  end

  test "calendar task composer route opens the task modal", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/calendar?composer=task")

    assert html =~ "New Task"
    assert html =~ "Add task title"
  end

  test "sidebar includes verified custom-domain mailbox addresses", %{conn: conn} do
    unique_id = System.unique_integer([:positive])
    user = AccountsFixtures.user_fixture(%{username: "sidebar#{unique_id}"})
    verified_domain = "mail#{unique_id}.sidebar.test"
    pending_domain = "pending#{unique_id}.sidebar.test"

    {:ok, custom_domain} = Email.create_custom_domain(user, %{"domain" => verified_domain})

    custom_domain
    |> Ecto.Changeset.change(%{status: "verified"})
    |> Repo.update!()

    assert {:ok, _pending_domain} =
             Email.create_custom_domain(user, %{"domain" => pending_domain})

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email")

    assert html =~ "#{user.username}@#{verified_domain}"
    refute html =~ "#{user.username}@#{pending_domain}"
  end

  test "folder message links preserve the folder context", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)
    {:ok, folder} = Email.create_custom_folder(%{user_id: user.id, name: "Receipts"})

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Folder link context",
        text_body: "Folder message body",
        html_body: "<p>Folder message body</p>",
        folder_id: folder.id,
        message_id: "<folder-link-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email?tab=folder&folder_id=#{folder.id}")

    assert html =~
             "/email/view/#{message.hash}?return_to=folder&amp;folder_id=#{folder.id}"
  end

  test "bulk delete keeps the digest filter active", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "newsletter@example.com",
        to: mailbox.email,
        subject: "Digest message",
        text_body: "Digest content",
        html_body: "<p>Digest content</p>",
        category: "feed",
        message_id: "<bulk-digest-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email?tab=inbox&filter=digest")

    view
    |> element("#message-checkbox-#{message.id}")
    |> render_click()

    view
    |> element("button[phx-click='bulk_action'][phx-value-action='delete']")
    |> render_click()

    assert has_element?(view, "a[href='/email?tab=inbox&filter=digest'].btn-secondary")
    assert render(view) =~ "Messages moved to trash"
    refute render(view) =~ "Digest message"
  end

  defp ensure_mailbox(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end
end
