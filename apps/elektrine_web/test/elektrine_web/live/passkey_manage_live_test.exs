defmodule ElektrineWeb.PasskeyManageLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias ElektrineWeb.UserAuth

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        username: "passkeyuser#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    %{user: user}
  end

  defp log_in_user(conn, user, opts \\ []) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)

    case Keyword.get(opts, :recent_auth_at) do
      recent_auth_at when is_integer(recent_auth_at) ->
        Plug.Conn.put_session(conn, UserAuth.recent_auth_session_key(), recent_auth_at)

      _ ->
        conn
    end
  end

  test "requires a recent login before starting passkey registration", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/passkeys")

    html =
      view
      |> element("#add-passkey-btn")
      |> render_click()

    assert html =~ "requires a recent login"
  end

  test "forged passkey events with malformed ids do not crash", %{conn: conn, user: user} do
    {:ok, view, _html} =
      conn
      |> log_in_user(user, recent_auth_at: System.system_time(:second))
      |> live(~p"/account/passkeys")

    assert render_hook(view, "start_rename", %{"id" => "12abc"}) =~ "Passkeys"

    assert render_hook(view, "save_rename", %{"passkey_id" => "12abc", "name" => "Work key"}) =~
             "Failed to rename passkey"

    assert render_hook(view, "delete_passkey", %{"id" => "12abc"}) =~ "Failed to delete passkey"
  end
end
