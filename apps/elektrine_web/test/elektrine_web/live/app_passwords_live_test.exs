defmodule ElektrineWeb.AppPasswordsLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

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
      |> log_in_user(user)
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
             "input[name='app_password[name]'][value='']"
           )

    refute has_element?(
             view,
             "#create-app-password-form input[name='app_password[name]'][value='Thunderbird on laptop']"
           )

    assert Enum.any?(Accounts.list_app_passwords(user.id), &(&1.name == "Thunderbird on laptop"))
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
