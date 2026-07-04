defmodule ElektrineWeb.ChatLiveThreadsTest do
  use Elektrine.DataCase, async: false

  alias ArblargWeb.ChatLive.Operations.ThreadOperations
  alias ArblargWeb.ChatLive.State
  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  defp channel_fixture do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "thread-ui", is_public: true})
    {:ok, _} = Messaging.join_server(server.id, member.id)
    [channel | _] = server.channels

    %{owner: owner, member: member, channel: channel}
  end

  defp socket_for(user, channel, overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          flash: %{},
          current_user: user,
          conversation: %{selected: channel},
          threads: %State.Threads{},
          context_menu: %State.ContextMenu{}
        },
        overrides
      )

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  test "full thread flow: create from message, reply, live updates, archive" do
    %{owner: owner, member: member, channel: channel} = channel_fixture()

    {:ok, root} =
      Messaging.create_chat_text_message(channel.id, member.id, "shall we discuss this?")

    socket = socket_for(owner, channel)

    # 1. Create a thread from the message context menu.
    assert {:noreply, socket} =
             ThreadOperations.handle_event(
               "create_thread",
               %{"message_id" => to_string(root.id)},
               socket
             )

    threads = socket.assigns.threads
    assert threads.show_panel
    assert threads.active.root_message_id == root.id
    assert threads.active.title == "shall we discuss this?"
    assert [listed] = threads.list
    assert listed.id == threads.active.id

    # The inline indicator helper resolves the thread for the root message.
    assert ThreadOperations.thread_for_message(threads, root.id).id == threads.active.id

    # 2. Send a reply through the panel composer.
    socket = put_in(socket.assigns.threads.composer, "first reply")

    assert {:noreply, socket} =
             ThreadOperations.handle_event(
               "send_thread_message",
               %{"message" => "first reply"},
               socket
             )

    assert socket.assigns.threads.composer == ""
    [reply] = Messaging.list_chat_thread_messages(socket.assigns.threads.active.id)
    assert reply.content == "first reply"
    assert reply.thread_id == socket.assigns.threads.active.id

    # The reply is excluded from the channel's main timeline.
    timeline_ids = Messaging.get_chat_messages(channel.id, user_id: owner.id) |> Enum.map(& &1.id)
    assert root.id in timeline_ids
    refute reply.id in timeline_ids

    # 3. The PubSub broadcast for the reply appends it to the open panel.
    assert {:handled, {:noreply, socket}} =
             ThreadOperations.route_info({:new_thread_message, reply}, socket)

    assert Enum.map(socket.assigns.threads.messages, & &1.id) == [reply.id]

    # A duplicate delivery does not append twice.
    assert {:handled, {:noreply, socket}} =
             ThreadOperations.route_info({:new_thread_message, reply}, socket)

    assert length(socket.assigns.threads.messages) == 1

    # The counter-bump broadcast keeps the open thread and list fresh.
    updated_thread = Messaging.get_chat_thread(socket.assigns.threads.active.id)

    assert {:handled, {:noreply, socket}} =
             ThreadOperations.route_info({:thread_updated, updated_thread}, socket)

    assert socket.assigns.threads.active.message_count == 1

    # 4. Archive from the panel; the broadcast clears it from the active list.
    assert {:noreply, socket} =
             ThreadOperations.handle_event(
               "archive_thread",
               %{"thread_id" => to_string(socket.assigns.threads.active.id)},
               socket
             )

    archived_thread = Messaging.get_chat_thread(socket.assigns.threads.active.id)
    assert archived_thread.archived_at

    assert {:handled, {:noreply, socket}} =
             ThreadOperations.route_info({:thread_archived, archived_thread}, socket)

    assert socket.assigns.threads.list == []
    assert socket.assigns.threads.active.archived_at

    # 5. The archived section lists it after toggling.
    assert {:noreply, socket} =
             ThreadOperations.handle_event("back_to_thread_list", %{}, socket)

    assert {:noreply, socket} =
             ThreadOperations.handle_event("toggle_archived_threads", %{}, socket)

    assert socket.assigns.threads.show_archived
    assert Enum.map(socket.assigns.threads.archived, & &1.id) == [archived_thread.id]

    # 6. Reopen the thread from the archived list.
    assert {:noreply, _socket} =
             ThreadOperations.handle_event(
               "unarchive_thread",
               %{"thread_id" => to_string(archived_thread.id)},
               socket
             )

    refute Messaging.get_chat_thread(archived_thread.id).archived_at
  end

  test "members without create_threads get a friendly error" do
    %{member: member, channel: channel} = channel_fixture()
    {:ok, root} = Messaging.create_chat_text_message(channel.id, member.id, "no thread")

    socket = socket_for(member, channel)

    assert {:noreply, socket} =
             ThreadOperations.handle_event(
               "create_thread",
               %{"message_id" => to_string(root.id)},
               socket
             )

    refute socket.assigns.threads.show_panel
    assert socket.assigns.flash["error"] =~ "permission"
  end

  test "panel toggle loads the active thread list" do
    %{owner: owner, channel: channel} = channel_fixture()
    {:ok, thread} = Messaging.create_chat_thread(channel.id, owner.id, %{title: "Sidebar"})

    socket = socket_for(owner, channel)

    assert {:noreply, socket} =
             ThreadOperations.handle_event("toggle_thread_panel", %{}, socket)

    assert socket.assigns.threads.show_panel
    assert Enum.map(socket.assigns.threads.list, & &1.id) == [thread.id]

    assert {:noreply, socket} =
             ThreadOperations.handle_event("toggle_thread_panel", %{}, socket)

    refute socket.assigns.threads.show_panel
  end
end
