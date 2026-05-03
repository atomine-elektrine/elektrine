defmodule ElektrineEmailWeb.EmailControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email

  test "iframe content moves leading CSS preamble out of the body", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "CSS preamble regression",
        html_body: """
        p { display:block;margin:13px 0; }
        @import url(https://fonts.googleapis.com/css2?family=Arvo);
        .emphasis { color:#a33600;font-weight:700; }<div class="emphasis">Hi Maxfield</div>
        """,
        message_id: "<css-preamble-#{System.unique_integer([:positive])}@example.com>"
      })

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/iframe_content")

    html = html_response(conn, 200)
    document = Floki.parse_document!(html)
    body_text = document |> Floki.find("body") |> Floki.text()

    assert body_text =~ "Hi Maxfield"
    refute body_text =~ "display:block"
    refute body_text =~ "@import"
    refute body_text =~ ".emphasis"
  end

  test "iframe content rewrites cid images and remote images", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Image rewrite regression",
        html_body: """
        <p>Images</p>
        <img src="cid:logo@example.com">
        <img src="https://example.com/open.png">
        <img srcset="https://example.com/open@2x.png 2x, https://example.com/open@1x.png 1x">
        <div style="background-image:url('https://example.com/bg.png')">Background</div>
        """,
        attachments: %{
          "attachment_0" => %{
            "filename" => "logo.png",
            "content_type" => "image/png",
            "content_id" => "<logo@example.com>",
            "disposition" => "inline",
            "data" => Base.encode64("png"),
            "encoding" => "base64"
          }
        },
        message_id: "<image-rewrite-#{System.unique_integer([:positive])}@example.com>"
      })

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/iframe_content")
      |> html_response(200)

    assert html =~ ~s(src="/email/message/#{message.id}/attachment/attachment_0/download")
    assert html =~ ~s(src="/email/image_proxy?token=)
    assert html =~ ~s(srcset="/email/image_proxy?token=)
    assert html =~ ~s(background-image:url(/email/image_proxy?token=)
    refute html =~ "cid:logo@example.com"
    refute html =~ "https://example.com/open.png"
    refute html =~ "https://example.com/open@2x.png"
    refute html =~ "https://example.com/bg.png"
  end

  test "original html endpoint returns source as text", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Source regression",
        html_body: "<style>p{color:red}</style><p>Original</p>",
        message_id: "<source-#{System.unique_integer([:positive])}@example.com>"
      })

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/original_html")

    assert response(conn, 200) == "<style>p{color:red}</style><p>Original</p>"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/plain"
  end

  test "plain text iframe content linkifies urls and email addresses", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Linkify regression",
        text_body: "Visit https://example.com/path?q=1 or email help@example.com",
        message_id: "<linkify-#{System.unique_integer([:positive])}@example.com>"
      })

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/iframe_content")
      |> html_response(200)

    assert html =~ ~s(href="https://example.com/path?q=1")
    assert html =~ ~s(href="mailto:help@example.com")
  end

  defp ensure_mailbox(user) do
    Email.get_user_mailbox(user.id) ||
      case Email.ensure_user_has_mailbox(user) do
        {:ok, mailbox} -> mailbox
        mailbox -> mailbox
      end
  end

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
end
