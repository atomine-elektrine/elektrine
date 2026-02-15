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

  test "can create and reveal a vault entry", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/password-manager")

    view
    |> form("#vault-entry-form", %{
      "entry" => %{
        "title" => "GitHub",
        "login_username" => "coder@example.com",
        "website" => "https://github.com",
        "password" => "SuperSecret123!",
        "notes" => "2FA enabled"
      }
    })
    |> render_submit()

    assert render(view) =~ "GitHub"

    [entry] = PasswordManager.list_entries(user.id)

    view
    |> element("#entry-#{entry.id} button[phx-click='reveal']")
    |> render_click()

    assert render(view) =~ "SuperSecret123!"
    assert render(view) =~ "2FA enabled"
  end

  test "can delete a vault entry", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, entry} =
      PasswordManager.create_entry(user.id, %{
        "title" => "Disposable",
        "password" => "temp-password"
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
end
