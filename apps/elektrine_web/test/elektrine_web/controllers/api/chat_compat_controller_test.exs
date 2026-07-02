defmodule ElektrineWeb.API.ChatCompatControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Repo
  alias ElektrineWeb.API.ChatCompatController

  describe "create_by_account/2" do
    test "creates or returns a direct chat with a local account", %{conn: conn} do
      user = user_fixture()
      recipient = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> ChatCompatController.create_by_account(%{"id" => to_string(recipient.id)})

      assert %{
               "id" => chat_id,
               "account" => %{"id" => recipient_id},
               "unread" => false,
               "pinned" => false
             } = json_response(conn, 201)

      assert recipient_id == to_string(recipient.id)
      assert {:ok, _conversation} = Messaging.get_chat_conversation!(chat_id, user.id)
    end
  end

  describe "index/2" do
    test "limits after selecting direct chats", %{conn: conn} do
      user = user_fixture()
      recipient = user_fixture()
      group_member = user_fixture()

      {:ok, direct_chat} = Messaging.create_dm_conversation(user.id, recipient.id)

      {:ok, _direct_message} =
        Messaging.create_chat_text_message(direct_chat.id, recipient.id, "dm")

      {:ok, group} =
        Messaging.create_chat_group_conversation(user.id, %{name: "Compat Group"}, [
          group_member.id
        ])

      {:ok, _group_message} =
        Messaging.create_chat_text_message(group.id, group_member.id, "group")

      conn =
        conn
        |> assign(:current_user, user)
        |> ChatCompatController.index(%{"limit" => "1"})

      assert [%{"id" => id, "last_message" => %{"content" => "dm"}}] = json_response(conn, 200)
      assert id == to_string(direct_chat.id)
    end
  end

  describe "chat messages" do
    test "sends, lists, reads, pins, and deletes chat messages", %{conn: conn} do
      user = user_fixture()
      recipient = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, recipient.id)

      create_conn =
        conn
        |> assign(:current_user, user)
        |> ChatCompatController.post_message(%{
          "id" => to_string(conversation.id),
          "content" => "hello privately"
        })

      assert %{
               "id" => message_id,
               "chat_id" => chat_id,
               "account_id" => account_id,
               "content" => "hello privately"
             } = json_response(create_conn, 201)

      assert chat_id == to_string(conversation.id)
      assert account_id == to_string(user.id)

      list_conn =
        build_conn()
        |> assign(:current_user, user)
        |> ChatCompatController.messages(%{"id" => to_string(conversation.id)})

      assert [%{"id" => ^message_id, "content" => "hello privately"}] =
               json_response(list_conn, 200)

      pin_conn =
        build_conn()
        |> assign(:current_user, user)
        |> ChatCompatController.pin(%{"id" => to_string(conversation.id)})

      assert %{"id" => ^chat_id, "pinned" => true} = json_response(pin_conn, 200)

      read_conn =
        build_conn()
        |> assign(:current_user, recipient)
        |> ChatCompatController.read_message(%{
          "id" => to_string(conversation.id),
          "message_id" => message_id
        })

      assert %{"id" => ^chat_id, "unread" => false} = json_response(read_conn, 200)

      delete_conn =
        build_conn()
        |> assign(:current_user, user)
        |> ChatCompatController.delete_message(%{
          "id" => to_string(conversation.id),
          "message_id" => message_id
        })

      assert %{"id" => ^message_id, "content" => ""} = json_response(delete_conn, 200)

      assert Repo.get!(ChatMessage, message_id).deleted_at
    end

    test "does not expose a chat to non-members", %{conn: conn} do
      user = user_fixture()
      recipient = user_fixture()
      outsider = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, recipient.id)

      conn =
        conn
        |> assign(:current_user, outsider)
        |> ChatCompatController.show(%{"id" => to_string(conversation.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end
end
