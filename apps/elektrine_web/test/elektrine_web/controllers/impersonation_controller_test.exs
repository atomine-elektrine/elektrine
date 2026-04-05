defmodule ElektrineWeb.ImpersonationControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  describe "POST /pripyat/stop-impersonation" do
    test "allows impersonated sessions to stop impersonating", %{conn: conn} do
      admin_user = AccountsFixtures.user_fixture() |> make_admin()
      impersonated_user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(impersonated_user)
        |> Plug.Conn.put_session(:impersonating_admin_id, admin_user.id)
        |> Plug.Conn.put_session(:impersonated_user_id, impersonated_user.id)
        |> post("/pripyat/stop-impersonation")

      assert redirected_to(conn) in ["/", "/onboarding"]

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Impersonation ended. You are now logged in as yourself."
    end

    test "shows a friendly error when not impersonating", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(user)
        |> post("/pripyat/stop-impersonation")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You are not currently impersonating anyone."
    end
  end

  defp make_admin(user) do
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
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
