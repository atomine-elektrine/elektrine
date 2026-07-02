defmodule ElektrineWeb.API.DirectConversationControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Messaging
  alias ElektrineWeb.API.DirectConversationController

  import Elektrine.AccountsFixtures

  describe "index/2" do
    test "lists direct conversations with participants and last status", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      {:ok, _message} =
        Messaging.create_chat_text_message(conversation.id, other_user.id, "hello")

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.index(%{"limit" => "10"})

      assert [conversation_json] = json_response(conn, 200)
      assert conversation_json["id"] == to_string(conversation.id)
      assert conversation_json["unread"] == true
      assert [%{"id" => account_id}] = conversation_json["accounts"]
      assert account_id == to_string(other_user.id)
      assert conversation_json["last_status"]["content"] == "hello"
    end

    test "limits after selecting direct conversations", %{conn: conn} do
      user = user_fixture()
      direct_user = user_fixture()
      group_user = user_fixture()

      {:ok, direct_conversation} = Messaging.create_dm_conversation(user.id, direct_user.id)

      {:ok, _direct_message} =
        Messaging.create_chat_text_message(direct_conversation.id, direct_user.id, "dm")

      {:ok, group_conversation} =
        Messaging.create_chat_group_conversation(user.id, %{name: "API Group"}, [group_user.id])

      {:ok, _group_message} =
        Messaging.create_chat_text_message(group_conversation.id, group_user.id, "group")

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.index(%{"limit" => "1"})

      assert [%{"id" => id, "last_status" => %{"content" => "dm"}}] = json_response(conn, 200)
      assert id == to_string(direct_conversation.id)
    end
  end

  describe "read/2" do
    test "marks direct conversation messages as read", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      {:ok, _message} =
        Messaging.create_chat_text_message(conversation.id, other_user.id, "hello")

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.read(%{"id" => to_string(conversation.id)})

      assert %{"id" => id, "unread" => false} = json_response(conn, 200)
      assert id == to_string(conversation.id)
    end

    test "marks all direct conversations as read", %{conn: conn} do
      user = user_fixture()
      first_user = user_fixture()
      second_user = user_fixture()
      {:ok, first} = Messaging.create_dm_conversation(user.id, first_user.id)
      {:ok, second} = Messaging.create_dm_conversation(user.id, second_user.id)

      {:ok, _first_message} =
        Messaging.create_chat_text_message(first.id, first_user.id, "first")

      {:ok, _second_message} =
        Messaging.create_chat_text_message(second.id, second_user.id, "second")

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.read_all(%{})

      assert conversations = json_response(conn, 200)

      assert Enum.sort(Enum.map(conversations, & &1["id"])) ==
               Enum.sort([to_string(first.id), to_string(second.id)])

      assert Enum.all?(conversations, &(&1["unread"] == false))
    end
  end

  describe "show/2" do
    test "returns a direct conversation by id", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.show(%{"id" => to_string(conversation.id)})

      assert %{"id" => id, "accounts" => [%{"id" => other_user_id}]} = json_response(conn, 200)
      assert id == to_string(conversation.id)
      assert other_user_id == to_string(other_user.id)
    end
  end

  describe "update/2" do
    test "accepts the current direct conversation recipients", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.update(%{
          "id" => to_string(conversation.id),
          "recipients" => [to_string(other_user.id)]
        })

      assert %{"id" => id, "accounts" => [%{"id" => other_user_id}]} = json_response(conn, 200)
      assert id == to_string(conversation.id)
      assert other_user_id == to_string(other_user.id)
    end

    test "serves the prefixed client-compatible update route", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)
      {:ok, token} = ElektrineWeb.Plugs.APIAuth.generate_token(user.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> patch("/api/v1/pleroma/conversations/#{conversation.id}", %{
          "recipients" => [to_string(other_user.id)]
        })

      assert %{"id" => id, "accounts" => [%{"id" => other_user_id}]} = json_response(conn, 200)
      assert id == to_string(conversation.id)
      assert other_user_id == to_string(other_user.id)
    end

    test "rejects recipient changes through the direct conversation compatibility path", %{
      conn: conn
    } do
      user = user_fixture()
      other_user = user_fixture()
      replacement_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.update(%{
          "id" => to_string(conversation.id),
          "recipients" => [to_string(replacement_user.id)]
        })

      assert %{"error" => "recipients must match the current direct conversation accounts"} =
               json_response(conn, 400)
    end
  end

  describe "statuses/2" do
    test "lists direct conversation messages newest first", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      {:ok, older} =
        Messaging.create_chat_text_message(conversation.id, other_user.id, "older")

      {:ok, newer} =
        Messaging.create_chat_text_message(conversation.id, user.id, "newer")

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.statuses(%{"id" => to_string(conversation.id)})

      assert [
               %{"id" => newer_id, "content" => "newer"},
               %{"id" => older_id, "content" => "older"}
             ] = json_response(conn, 200)

      assert newer_id == to_string(newer.id)
      assert older_id == to_string(older.id)
    end

    test "supports max_id pagination and link headers", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      {:ok, older} = Messaging.create_chat_text_message(conversation.id, other_user.id, "older")
      {:ok, newer} = Messaging.create_chat_text_message(conversation.id, other_user.id, "newer")

      first_page =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.statuses(%{
          "id" => to_string(conversation.id),
          "limit" => "1"
        })

      assert [%{"id" => newer_id}] = json_response(first_page, 200)
      assert newer_id == to_string(newer.id)
      assert get_resp_header(first_page, "link") |> List.first() =~ "max_id=#{newer.id}"

      second_page =
        build_conn()
        |> assign(:current_user, user)
        |> DirectConversationController.statuses(%{
          "id" => to_string(conversation.id),
          "limit" => "1",
          "max_id" => to_string(newer.id)
        })

      assert [%{"id" => older_id, "content" => "older"}] = json_response(second_page, 200)
      assert older_id == to_string(older.id)
    end

    test "does not expose conversations to non-members", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      outsider = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      conn =
        conn
        |> assign(:current_user, outsider)
        |> DirectConversationController.statuses(%{"id" => to_string(conversation.id)})

      assert %{"error" => "conversation not found"} = json_response(conn, 404)
    end
  end

  describe "delete/2" do
    test "leaves a direct conversation for the current user", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(user.id, other_user.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> DirectConversationController.delete(%{"id" => to_string(conversation.id)})

      assert %{"id" => id, "deleted" => true} = json_response(conn, 200)
      assert id == to_string(conversation.id)
      assert {:error, :not_found} = Messaging.get_chat_conversation!(conversation.id, user.id)
    end
  end
end
