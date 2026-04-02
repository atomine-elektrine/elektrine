defmodule ElektrineWeb.Platform.AdminSubsetTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  setup do
    original_enabled = Application.get_env(:elektrine, :platform_modules)
    original_compiled = Application.get_env(:elektrine, :compiled_platform_modules)

    on_exit(fn ->
      restore_env(:platform_modules, original_enabled)
      restore_env(:compiled_platform_modules, original_compiled)
    end)

    :ok
  end

  test "admin dashboard still renders when email is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    admin = admin_user_fixture()

    conn =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> get("/pripyat")

    html = html_response(conn, 200)

    assert html =~ "Admin Dashboard"
    refute html =~ "Domain Health"
    refute html =~ "/pripyat/custom-domains"
  end

  test "account lookup hides email-only search when email is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    admin = admin_user_fixture()

    conn =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> get("/pripyat/account-lookup")

    html = html_response(conn, 200)

    assert html =~ "Account Investigation"
    refute html =~ "Email Address"
    assert html =~ "Username"
  end

  test "user edit page omits alias card when email is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    admin = admin_user_fixture()
    user = AccountsFixtures.user_fixture()

    conn =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> get("/pripyat/users/#{user.id}/edit")

    html = html_response(conn, 200)

    assert html =~ "Edit User"
    refute html =~ "Email Aliases"
  end

  test "unsubscribe stats route returns 404 when email is disabled", %{conn: conn} do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat])

    admin = admin_user_fixture()

    conn =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> get("/pripyat/unsubscribe-stats")

    assert response(conn, 404) == "Not Found"
  end

  defp restore_env(key, nil), do: Application.delete_env(:elektrine, key)
  defp restore_env(key, value), do: Application.put_env(:elektrine, key, value)

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
      })

    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
