defmodule ElektrineWeb.Admin.ElevatePageTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  test "renders the elevation prompt and back link", %{conn: conn} do
    admin = admin_user_fixture()

    html =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> get("/pripyat/security/elevate?return_to=/pripyat/users")
      |> html_response(200)

    assert html =~ "Verify admin access"
    assert html =~ "Back to previous admin page"
    assert html =~ ~s(href="/pripyat/users")
    # A fresh admin has no passkey, so the registration prompt shows.
    assert html =~ "No passkey registered"
  end

  test "shows the passkey flow hooks when the admin has a passkey", %{conn: conn} do
    admin = admin_user_fixture()
    passkey_fixture(admin)

    html =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> get("/pripyat/security/elevate?return_to=/pripyat/users")
      |> html_response(200)

    # The passkey flow hooks the JS depends on must be present verbatim.
    assert html =~ ~s(data-admin-elevation="true")
    assert html =~ ~s(id="admin-elevate-passkey")
    assert html =~ ~s(data-return-to="/pripyat/users")
    assert html =~ "Verify with passkey"
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp passkey_fixture(user) do
    unique = :crypto.strong_rand_bytes(16)

    %Elektrine.Accounts.PasskeyCredential{}
    |> Elektrine.Accounts.PasskeyCredential.create_changeset(%{
      user_id: user.id,
      credential_id: unique,
      public_key: :crypto.strong_rand_bytes(32),
      user_handle: :crypto.strong_rand_bytes(16),
      name: "Test key"
    })
    |> Elektrine.Repo.insert!()
  end

  defp with_elektrine_host(conn), do: Map.put(conn, :host, "example.com")

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
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
