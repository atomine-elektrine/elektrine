defmodule ElektrineWeb.AppPasswordsLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.UserAuth

  defp log_in_user(conn, user, opts \\ []) do
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
    |> maybe_mark_recent_auth(opts)
  end

  defp maybe_mark_recent_auth(conn, recent_auth: true) do
    Plug.Conn.put_session(conn, UserAuth.recent_auth_session_key(), System.system_time(:second))
  end

  defp maybe_mark_recent_auth(conn, _opts), do: conn

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, reason} = live(conn, ~p"/account/app-passwords")

    redirect_to =
      case reason do
        {:redirect, %{to: to}} -> to
        {:live_redirect, %{to: to}} -> to
      end

    assert String.starts_with?(redirect_to, "/login")
  end

  test "resets app name input after creating an app password", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user, recent_auth: true)
      |> live(~p"/account/app-passwords")

    assert has_element?(view, "form[id^='create-app-password-form-']")

    assert has_element?(
             view,
             "input[name='app_password[name]'][value='']"
           )

    view
    |> form("form[id^='create-app-password-form-']", %{
      "app_password" => %{
        "name" => "Thunderbird on laptop",
        "expires_at" => "never"
      }
    })
    |> render_submit()

    assert render(view) =~ "App Password Created"

    assert has_element?(
             view,
             ~s(#copy-new-app-password-token[phx-hook="CopyToClipboard"][data-content])
           )

    assert has_element?(
             view,
             ~s(#copy-email-client-configuration[phx-hook="CopyToClipboard"][data-copy-target="email-client-configuration-copy-text"])
           )

    html = render(view)
    assert html =~ ~s(id="email-client-configuration-copy-text")
    assert html =~ "Username: #{user.username}"
    assert html =~ "IMAP (Recommended)"
    assert html =~ "SMTP (Outgoing)"
    assert html =~ "POP3 (Alternative)"

    assert has_element?(
             view,
             "input[name='app_password[name]'][value='']"
           )

    refute has_element?(
             view,
             "#create-app-password-form input[name='app_password[name]'][value='Thunderbird on laptop']"
           )

    assert Enum.any?(Accounts.list_app_passwords(user.id), &(&1.name == "Thunderbird on laptop"))
  end

  test "requires recent auth before creating an app password", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/app-passwords")

    view
    |> form("form[id^='create-app-password-form-']", %{
      "app_password" => %{
        "name" => "Thunderbird on laptop",
        "expires_at" => "never"
      }
    })
    |> render_submit()

    assert render(view) =~ "Managing app passwords requires a recent login"
    refute Enum.any?(Accounts.list_app_passwords(user.id), &(&1.name == "Thunderbird on laptop"))
  end

  test "requires recent auth before deleting an app password", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, app_password} = Accounts.create_app_password(user.id, %{name: "Thunderbird"})

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/app-passwords")

    view
    |> element("button[phx-click='delete'][phx-value-id='#{app_password.id}']")
    |> render_click()

    assert render(view) =~ "Managing app passwords requires a recent login"
    assert Accounts.app_password_exists?(app_password.id, user.id)
  end

  test "uses the shared account settings shell", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/app-passwords")

    html = render(view)

    refute html =~ "Back to account settings"
    assert html =~ "Account Settings"
    assert html =~ ~s(href="/account?tab=security")
    assert html =~ "E Profile"
  end
end
