defmodule ElektrineWeb.StorageLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures

  test "recalculates storage once while establishing live connection", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    user_id = user.id

    Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user_id}")

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/storage")

    assert html =~ "Storage Overview"
    assert_receive {:storage_updated, %{user_id: ^user_id}}
    refute_receive {:storage_updated, %{user_id: ^user_id}}
  end

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
