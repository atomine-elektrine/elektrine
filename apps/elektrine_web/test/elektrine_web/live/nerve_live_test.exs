defmodule ElektrineWeb.NerveLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Nerve

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

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, reason} = live(conn, ~p"/account/nerve")

    assert match?({:redirect, %{to: "/login"}}, reason) or
             match?({:live_redirect, %{to: "/login"}}, reason)
  end

  test "can create a nerve entry with encrypted payload", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _settings} =
             Nerve.setup_nerve(user.id, %{
               "encrypted_verifier" => encrypted_payload("verifier")
             })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/nerve")

    assert has_element?(view, "nav a[href=\"/portal\"]")
    assert has_element?(view, "nav a[href=\"/email\"]")
    assert has_element?(view, "nav a[href=\"/vpn\"]")
    assert has_element?(view, "nav a[href=\"/account/nerve\"]")

    assert has_element?(
             view,
             "nav a[href=\"/account/nerve\"][aria-current=\"page\"]"
           )

    assert has_element?(
             view,
             "a[href=\"/account/nerve/extension/chromium/download\"]",
             "Download Chromium ZIP"
           )

    assert has_element?(
             view,
             "a[href=\"/account/nerve/extension/firefox/download\"]",
             "Download Firefox XPI"
           )

    html = render(view)
    assert html =~ "Unlock Bridge"
    assert html =~ "Browser Extension"
    assert html =~ "Connected Devices"
    assert html =~ "Site Connections"
    assert html =~ "This Browser"

    render_submit(view, "create", %{
      "entry" => %{
        "title" => "GitHub",
        "login_username" => "coder@example.com",
        "website" => "https://github.com",
        "encrypted_metadata" => Jason.encode!(encrypted_payload("metadata")),
        "encrypted_password" => Jason.encode!(encrypted_payload("SuperSecret123!")),
        "encrypted_notes" => Jason.encode!(encrypted_payload("2FA enabled"))
      }
    })

    assert render(view) =~ "Encrypted entry"
    html = render(view)
    assert html =~ "github.com"
    assert html =~ "Known Sites"
    refute html =~ "data-encrypted-password"
    refute html =~ "data-encrypted-notes"

    [entry] = Nerve.list_entries(user.id, include_secrets: true)
    assert entry.encrypted_password["algorithm"] == "AES-GCM"
    assert entry.encrypted_notes["ciphertext"] != ""
  end

  test "can delete a nerve entry", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _settings} =
             Nerve.setup_nerve(user.id, %{
               "encrypted_verifier" => encrypted_payload("verifier")
             })

    {:ok, entry} =
      Nerve.create_entry(user.id, %{
        "title" => "Disposable",
        "encrypted_metadata" => encrypted_payload("metadata"),
        "encrypted_password" => encrypted_payload("temp-password")
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/nerve")

    assert render(view) =~ "Encrypted entry"

    view
    |> element("#entry-#{entry.id} button[phx-click='delete']")
    |> render_click()

    refute render(view) =~ "Encrypted entry"
  end

  test "can delete a nerve and start over", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _settings} =
             Nerve.setup_nerve(user.id, %{
               "encrypted_verifier" => encrypted_payload("verifier")
             })

    {:ok, _entry} =
      Nerve.create_entry(user.id, %{
        "title" => "Disposable",
        "encrypted_metadata" => encrypted_payload("metadata"),
        "encrypted_password" => encrypted_payload("temp-password")
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/nerve")

    assert render(view) =~ "Delete Bridge"

    view
    |> element("#delete-nerve-button")
    |> render_click()

    refute Nerve.nerve_configured?(user.id)
    assert Nerve.list_entries(user.id, include_secrets: true) == []
    assert render(view) =~ "Set Bridge Passphrase"
  end

  defp encrypted_payload(value) do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => 210_000,
      "salt" => Base.encode64("1234567890123456"),
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext:" <> value)
    }
  end
end
