defmodule ElektrineChatWeb.ChatLive.Operations.MessageInfoOperationsTest do
  use ExUnit.Case, async: true

  alias ElektrineChatWeb.ChatLive.Operations.MessageInfoOperations

  test "handle_chat_message_deleted/2 removes the message from assigns" do
    socket = socket_fixture()

    assert {:noreply, updated_socket} =
             MessageInfoOperations.handle_chat_message_deleted(socket, 1)

    assert Enum.map(updated_socket.assigns.messages, & &1.id) == [2]
  end

  test "handle_chat_reaction_added/3 avoids duplicate reactions" do
    reaction = %{emoji: "👍", user_id: 10, remote_actor_id: nil}
    message = %{id: 1, conversation_id: 10, reactions: [reaction]}
    socket = socket_fixture(%{messages: [message]})

    assert {:noreply, updated_socket} =
             MessageInfoOperations.handle_chat_reaction_added(socket, 1, reaction)

    [updated_message] = updated_socket.assigns.messages
    assert length(updated_message.reactions) == 1
  end

  test "handle_chat_remote_read_receipt/2 appends remote reader once per actor" do
    socket =
      socket_fixture(%{
        message: %{read_status: %{1 => [%{remote_actor_id: 44, username: "@old", avatar: nil}]}}
      })

    receipt = %{message_id: 1, remote_actor_id: 44, username: "@new", avatar: "avatar.png"}

    assert {:noreply, updated_socket} =
             MessageInfoOperations.handle_chat_remote_read_receipt(socket, receipt)

    readers = updated_socket.assigns.message.read_status[1]
    assert length(readers) == 1
    assert hd(readers).username == "@new"
  end

  test "handle_chat_remote_read_cursor/2 updates all visible messages up to the cursor" do
    socket = socket_fixture(%{message: %{read_status: %{2 => [%{remote_actor_id: 44}]}}})

    cursor = %{read_through_message_id: 2, remote_actor_id: 44, username: "@reader"}

    assert {:noreply, updated_socket} =
             MessageInfoOperations.handle_chat_remote_read_cursor(socket, cursor)

    assert length(updated_socket.assigns.message.read_status[1]) == 1
    assert length(updated_socket.assigns.message.read_status[2]) == 1
    assert hd(updated_socket.assigns.message.read_status[2]).username == "@reader"
  end

  test "handle_federation_presence_update/2 updates only the selected conversation entries" do
    socket = socket_fixture(%{federation_presence: %{}})

    payload = %{
      conversation_id: 10,
      remote_actor_id: 99,
      handle: "@alice@example.com",
      label: "Alice",
      status: "online"
    }

    assert {:noreply, updated_socket} =
             MessageInfoOperations.handle_federation_presence_update(socket, payload)

    assert updated_socket.assigns.federation_presence[99].status == "online"

    assert {:noreply, unchanged_socket} =
             MessageInfoOperations.handle_federation_presence_update(
               updated_socket,
               Map.put(payload, :conversation_id, 77)
             )

    assert map_size(unchanged_socket.assigns.federation_presence) == 1
  end

  test "handle_notification_count_updated/2 updates notification_count assign" do
    socket = socket_fixture(%{notification_count: 1})

    assert {:noreply, updated_socket} =
             MessageInfoOperations.handle_notification_count_updated(socket, 42)

    assert updated_socket.assigns.notification_count == 42
  end

  test "route_info/2 routes known events and reports unknown messages as unhandled" do
    socket = socket_fixture()

    assert {:handled, {:noreply, routed_socket}} =
             MessageInfoOperations.route_info({:chat_message_deleted, 1}, socket)

    assert Enum.map(routed_socket.assigns.messages, & &1.id) == [2]
    assert :unhandled == MessageInfoOperations.route_info(:something_else, socket)
  end

  defp socket_fixture(overrides \\ %{}) do
    base_assigns = %{
      conversation: %{selected: %{id: 10}},
      messages: [
        %{id: 1, conversation_id: 10, reactions: [], link_preview: nil},
        %{id: 2, conversation_id: 10, reactions: [], link_preview: nil}
      ],
      message: %{read_status: %{}},
      active_server_id: 55,
      federation_presence: %{},
      notification_count: 0,
      __changed__: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base_assigns, overrides)}
  end
end
