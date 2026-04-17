defmodule ElektrineWeb.ChatLiveIndexTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias ElektrineChatWeb.ChatLive.Index

  test "user_read_messages updates visible message read status" do
    user = AccountsFixtures.user_fixture()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: user,
        conversation: %{
          list: [],
          selected: %{id: 123}
        },
        messages: [],
        message: %{read_status: %{1 => [%{username: "alice"}]}},
        first_unread_message_id: 456
      }
    }

    assert {:noreply, updated_socket} = Index.handle_info({:user_read_messages, user.id}, socket)

    assert updated_socket.assigns.message.read_status == %{}
    assert updated_socket.assigns.first_unread_message_id == nil
  end
end
