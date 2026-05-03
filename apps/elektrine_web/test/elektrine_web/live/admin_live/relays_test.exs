defmodule ElektrineWeb.AdminLive.RelaysTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias ElektrineWeb.AdminSecurity

  test "mutating relay events re-elevate back to the relay page", %{conn: conn} do
    admin = admin_user_fixture()

    {:ok, view, _html} =
      conn
      |> with_elektrine_host()
      |> log_in_as(admin)
      |> Plug.Conn.put_session(
        :admin_last_resign_at,
        System.system_time(:second) - AdminSecurity.action_grant_ttl_seconds() - 1
      )
      |> live(~p"/pripyat/relays")

    _ = render_click(view, "force_delete", %{"uri" => "https://relay.example/actor"})

    assert_redirect(view, "/pripyat/security/elevate?return_to=%2Fpripyat%2Frelays")
  end

  defp admin_user_fixture do
    user = AccountsFixtures.user_fixture()
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
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

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> AdminSecurity.initialize_admin_session(user, auth_method: :passkey)
  end
end
