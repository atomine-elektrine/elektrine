defmodule ElektrineWeb.PasswordManagerLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.PasswordManager

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, reason} = live(conn, ~p"/account/password-manager")

    assert match?({:redirect, %{to: "/login"}}, reason) or
             match?({:live_redirect, %{to: "/login"}}, reason)
  end

  test "can create a vault entry with encrypted payload", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _settings} =
             PasswordManager.setup_vault(user.id, %{
               "encrypted_verifier" => encrypted_payload("verifier")
             })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/password-manager")

    assert has_element?(view, "nav a[href=\"/overview\"]")
    assert has_element?(view, "nav a[href=\"/search\"]")
    assert has_element?(view, "nav a[href=\"/email\"]")
    assert has_element?(view, "nav a[href=\"/vpn\"]")
    assert has_element?(view, "nav a[href=\"/account/password-manager\"]")

    assert has_element?(
             view,
             "nav a[href=\"/account/password-manager\"][aria-current=\"page\"]"
           )

    render_submit(view, "create", %{
      "entry" => %{
        "title" => "GitHub",
        "login_username" => "coder@example.com",
        "website" => "https://github.com",
        "encrypted_password" => Jason.encode!(encrypted_payload("SuperSecret123!")),
        "encrypted_notes" => Jason.encode!(encrypted_payload("2FA enabled"))
      }
    })

    assert render(view) =~ "GitHub"

    [entry] = PasswordManager.list_entries(user.id, include_secrets: true)
    assert entry.encrypted_password["algorithm"] == "AES-GCM"
    assert entry.encrypted_notes["ciphertext"] != ""
  end

  test "can delete a vault entry", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _settings} =
             PasswordManager.setup_vault(user.id, %{
               "encrypted_verifier" => encrypted_payload("verifier")
             })

    {:ok, entry} =
      PasswordManager.create_entry(user.id, %{
        "title" => "Disposable",
        "encrypted_password" => encrypted_payload("temp-password")
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/password-manager")

    assert render(view) =~ "Disposable"

    view
    |> element("#entry-#{entry.id} button[phx-click='delete']")
    |> render_click()

    refute render(view) =~ "Disposable"
  end

  test "can delete a vault and start over", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _settings} =
             PasswordManager.setup_vault(user.id, %{
               "encrypted_verifier" => encrypted_payload("verifier")
             })

    {:ok, _entry} =
      PasswordManager.create_entry(user.id, %{
        "title" => "Disposable",
        "encrypted_password" => encrypted_payload("temp-password")
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/password-manager")

    assert render(view) =~ "Delete Vault"

    view
    |> element("#delete-vault-button")
    |> render_click()

    refute PasswordManager.vault_configured?(user.id)
    assert PasswordManager.list_entries(user.id, include_secrets: true) == []
    assert render(view) =~ "Set Vault Passphrase"
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
