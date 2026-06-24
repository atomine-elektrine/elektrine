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

  test "forged attachment delete events with malformed ids do not crash", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/storage")

    assert render_hook(view, "delete_chat_attachment", %{"message_id" => "12abc"}) =~
             "Unauthorized or message not found"

    assert render_hook(view, "delete_email_attachment", %{
             "message_id" => "12abc",
             "attachment_id" => "att-1"
           }) =~ "Message not found or access denied"
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
