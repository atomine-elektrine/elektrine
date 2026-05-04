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

  test "iframe content keeps marketing-email layout assets permissive", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Marketing layout regression",
        html_body: """
        <html>
          <head>
            <link rel="stylesheet" href="https://cdn.example.com/email.css">
          </head>
          <body>
            <picture>
              <source media="(min-width: 600px)" srcset="https://example.com/hero-wide.jpg 1x">
              <img src="https://example.com/hero.jpg" width="720" height="320" alt="Hero">
            </picture>
            <video controls poster="https://example.com/poster.jpg"></video>
          </body>
        </html>
        """,
        message_id: "<marketing-layout-#{System.unique_integer([:positive])}@example.com>"
      })

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/iframe_content")

    html = html_response(conn, 200)
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "script-src 'none'"
    assert csp =~ "frame-src 'none'"
    assert csp =~ "form-action 'none'"
    assert csp =~ "img-src 'self' data: cid: https:"
    assert csp =~ "media-src 'self' data: cid: https:"
    assert html =~ ~s(rel="stylesheet")
    assert html =~ ~s(srcset="/email/image_proxy?token=)
    assert html =~ ~s(src="/email/image_proxy?token=)
    assert html =~ ~s(poster="/email/image_proxy?token=)
    refute html =~ "max-width: 100%"
    refute html =~ "display: none !important"
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

  test "plain text iframe content removes broken CSS font import fragments", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Plain text CSS regression",
        text_body: """
        700&display=swap');

        /* iOS BLUE LINKS */
        a[x-apple-data-detectors] { color: inherit !important; }
        [style*='Noto Sans'] { font-family: 'Indeed Sans', 'Noto Sans', sans-serif !important; }

        Find immediate job opportunities

        Apply now to companies hiring fast
        """,
        message_id: "<plain-css-#{System.unique_integer([:positive])}@example.com>"
      })

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/iframe_content")
      |> html_response(200)

    body_text = html |> Floki.parse_document!() |> Floki.find("body") |> Floki.text()

    refute body_text =~ "display=swap"
    refute body_text =~ "iOS BLUE LINKS"
    refute body_text =~ "x-apple-data-detectors"
    refute body_text =~ "Noto Sans"
    assert body_text =~ "Find immediate job opportunities"
    assert body_text =~ "Apply now to companies hiring fast"
  end

  test "iframe content preserves body attributes and non-Outlook CSS", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = ensure_mailbox(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Body CSS regression",
        html_body: """
        <html>
          <head>
            <!--[if !mso]><!-->
            <style>.modern-client { color: #123456; }</style>
            <!--<![endif]-->
            <!--[if mso]><style>.outlook-only { color: red; }</style><![endif]-->
          </head>
          <body style="margin:0;padding:0" bgcolor="#f3f2f1">
            <table role="presentation"><tr><td class="modern-client">Modern body</td></tr></table>
          </body>
        </html>
        """,
        message_id: "<body-css-#{System.unique_integer([:positive])}@example.com>"
      })

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/email/#{message.id}/iframe_content")
      |> html_response(200)

    document = Floki.parse_document!(html)

    assert html =~ ".modern-client"
    refute html =~ ".outlook-only"
    assert Floki.attribute(document, "body", "bgcolor") == ["#f3f2f1"]
    assert Floki.attribute(document, "body", "style") == ["margin:0;padding:0"]
    assert document |> Floki.find("body") |> Floki.text() =~ "Modern body"
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
