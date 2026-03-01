defmodule ElektrineWeb.Admin.ChatMessagesControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Ecto.Query

  alias Elektrine.{Accounts, AuditLog, Messaging, Repo}
  alias Elektrine.AccountsFixtures

  describe "admin arblarg chat message views" do
    test "renders message console and logs list view", %{conn: conn} do
      %{admin: admin} = admin_chat_message_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/arblarg/messages")

      assert html_response(conn, 200) =~ "Arblarg Message Console"

      log = latest_list_log(admin.id)
      assert log.action == "view_chat_messages"
      assert log.resource_type == "chat_message_list"
      assert log.details["route_context"] == "admin_arblarg_messages"
      assert log.details["result_count"] >= 1
    end

    test "renders message detail and logs view", %{conn: conn} do
      %{admin: admin, message: message} = admin_chat_message_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/arblarg/messages/#{message.id}/view")

      assert html_response(conn, 200) =~ "Arblarg Chat Message"

      log = latest_message_log(admin.id, message.id)
      assert log.action == "view_chat_message"
      assert log.resource_type == "chat_message"
      assert log.details["view_format"] == "html"
    end

    test "renders raw message and logs raw view", %{conn: conn} do
      %{admin: admin, message: message} = admin_chat_message_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/arblarg/messages/#{message.id}/raw")

      assert response(conn, 200) =~ "ARBLARG CHAT MESSAGE"

      log = latest_message_log(admin.id, message.id)
      assert log.action == "view_chat_message"
      assert log.resource_type == "chat_message"
      assert log.details["view_format"] == "raw"
    end
  end

  defp admin_chat_message_fixture do
    admin = AccountsFixtures.user_fixture() |> make_admin()
    sender = AccountsFixtures.user_fixture()

    {:ok, conversation} =
      Messaging.create_group_conversation(sender.id, %{
        name: "arbp-test-#{System.unique_integer([:positive])}",
        description: "Arblarg test conversation"
      })

    {:ok, message} =
      Messaging.create_chat_text_message(
        conversation.id,
        sender.id,
        "Arblarg test message #{System.unique_integer([:positive])}"
      )

    %{admin: admin, sender: sender, conversation: conversation, message: message}
  end

  defp latest_list_log(admin_id) do
    Repo.one!(
      from(a in AuditLog,
        where:
          a.admin_id == ^admin_id and
            a.action == "view_chat_messages" and
            a.resource_type == "chat_message_list",
        order_by: [desc: a.inserted_at],
        limit: 1
      )
    )
  end

  defp latest_message_log(admin_id, message_id) do
    Repo.one!(
      from(a in AuditLog,
        where:
          a.admin_id == ^admin_id and
            a.action == "view_chat_message" and
            a.resource_type == "chat_message" and
            a.resource_id == ^message_id,
        order_by: [desc: a.inserted_at],
        limit: 1
      )
    )
  end

  defp make_admin(user) do
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "elektrine.com")
  end

  defp log_in_as(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)
    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
