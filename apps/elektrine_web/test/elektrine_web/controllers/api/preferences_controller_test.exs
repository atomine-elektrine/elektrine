defmodule ElektrineWeb.API.PreferencesControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts

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

  describe "PUT /api/preferences/theme" do
    test "persists the toggled theme mode", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/preferences/theme", %{"mode" => "dark"})

      assert json_response(conn, 200) == %{"theme_mode" => "dark"}
      assert Accounts.get_user!(user.id).theme_mode == "dark"
    end

    test "rejects unsupported theme modes", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/preferences/theme", %{"mode" => "neon"})

      assert json_response(conn, 422)["error"]
      assert Accounts.get_user!(user.id).theme_mode == "system"
    end

    test "requires authentication", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/preferences/theme", %{"mode" => "dark"})

      assert conn.halted
      assert conn.status == 302
    end
  end
end
