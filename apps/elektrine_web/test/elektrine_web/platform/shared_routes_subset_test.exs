defmodule ElektrineWeb.Platform.SharedRoutesSubsetTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Profiles

  setup do
    original_enabled = Application.get_env(:elektrine, :platform_modules)
    original_compiled = Application.get_env(:elektrine, :compiled_platform_modules)

    on_exit(fn ->
      restore_env(:platform_modules, original_enabled)
      restore_env(:compiled_platform_modules, original_compiled)
    end)

    :ok
  end

  test "overview still renders when optional modules are disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [])

    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    assert html =~ "Attention Queue"
    refute html =~ "Compose Email"
    refute html =~ "New Message"
    refute html =~ "New Post"
  end

  test "account routes still render when email is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account?tab=email")

    assert html =~ "Profile Information"
    refute html =~ "Manage App Passwords"

    {:ok, storage_view, _storage_html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/storage")

    refute has_element?(storage_view, ~s(button[phx-value-tab="emails"]))
  end

  test "password change page still renders when email is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    user = AccountsFixtures.user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/account/password")

    assert html_response(conn, 200) =~ "Change Password"
  end

  test "profile page still renders when social is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [])

    user = AccountsFixtures.user_fixture()

    {:ok, _profile} =
      Profiles.create_user_profile(user.id, %{
        display_name: "Subset Profile",
        description: "Profile should load without social helpers",
        is_public: true
      })

    conn = get(conn, "/#{user.handle}")

    assert html_response(conn, 200) =~ "Subset Profile"
  end

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)

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
