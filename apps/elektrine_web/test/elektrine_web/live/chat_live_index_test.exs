defmodule ElektrineWeb.ChatLiveIndexTest do
  use Elektrine.DataCase, async: false

  alias ArblargWeb.ChatLive.Index
  alias ArblargWeb.ChatLive.Operations.ContextMenuOperations
  alias ArblargWeb.ChatLive.Operations.ConversationOperations
  alias ArblargWeb.ChatLive.Operations.DirectMessageOperations
  alias ArblargWeb.ChatLive.Operations.GroupChannelOperations
  alias ArblargWeb.ChatLive.Operations.MemberOperations
  alias ArblargWeb.ChatLive.Operations.MessageOperations
  alias ArblargWeb.ChatLive.Operations.UIOperations, as: ChatUIOperations
  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  test "mount redirects instead of crashing when current_user is missing" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:ok, updated_socket} = Index.mount(%{}, %{}, socket)
    assert {:redirect, %{to: "/login"}} = updated_socket.redirected
  end

  test "safe_chat_image_url rejects unsafe image values" do
    refute Index.safe_chat_image_url("javascript:alert(1)")
    refute Index.safe_chat_image_url("/admin/internal.png")
    refute Index.safe_chat_image_url("https://example.com/not-image")
  end

  test "safe_chat_image_url accepts local uploads and safe public images" do
    assert Index.safe_chat_image_url("uploads/avatars/chat.png") == "/uploads/avatars/chat.png"
    assert Index.safe_chat_image_url("/uploads/avatars/chat.png") == "/uploads/avatars/chat.png"

    assert Index.safe_chat_image_url("https://example.com/chat.png") ==
             "https://example.com/chat.png"
  end

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

  test "encrypted sends update the local conversation list preview" do
    alice = AccountsFixtures.user_fixture()
    bob = AccountsFixtures.user_fixture()

    {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
    {:ok, _} = Messaging.register_chat_encryption_device(alice.id, device_attrs("alice-device"))
    {:ok, _} = Messaging.register_chat_encryption_device(bob.id, device_attrs("bob-device"))

    conversations = Messaging.list_chat_conversations(alice.id)
    payload = encrypted_payload("key-preview-123")

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        active_server_id: nil,
        current_user: alice,
        conversation: %{
          list: conversations,
          filtered: conversations,
          selected: conversation,
          unread_count: 0,
          unread_counts: %{},
          last_message_read_status: %{}
        },
        messages: [],
        message: %{
          new_message: "",
          reply_to: nil,
          loading_messages: false,
          read_status: %{}
        },
        search: %{conversation_query: ""}
      }
    }

    assert {:reply, %{ok: true}, updated_socket} =
             Index.handle_event(
               "send_client_encrypted_message",
               %{
                 "encrypted_payload" => payload,
                 "key_packages" => [
                   key_package(alice.id, "alice-device"),
                   key_package(bob.id, "bob-device")
                 ],
                 "search_index" => ["client-token"]
               },
               socket
             )

    updated_conversation =
      Enum.find(updated_socket.assigns.conversation.list, &(&1.id == conversation.id))

    assert [preview_message] = updated_conversation.messages
    assert preview_message.client_encrypted_payload == payload
    assert updated_conversation.last_message_at
    assert updated_socket.assigns.conversation.unread_counts[conversation.id] == 0
  end

  test "incoming messages in an open chat notify senders that they were read" do
    alice = AccountsFixtures.user_fixture()
    bob = AccountsFixtures.user_fixture()

    {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
    {:ok, message} = Messaging.create_chat_text_message(conversation.id, alice.id, "hello")
    bob_id = bob.id

    Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{conversation.id}")

    receiver_socket = chat_socket(bob, conversation, messages: [])

    assert {:noreply, _updated_receiver_socket} =
             Index.handle_info({:new_chat_message, message}, receiver_socket)

    assert_receive {:user_read_messages, ^bob_id}

    sender_socket = chat_socket(alice, conversation, messages: [message])

    assert {:noreply, updated_sender_socket} =
             Index.handle_info({:user_read_messages, bob.id}, sender_socket)

    assert [%{user_id: bob_id}] =
             Map.get(updated_sender_socket.assigns.message.read_status, message.id)

    assert bob_id == bob.id
  end

  test "add member event respects blocked users" do
    creator = AccountsFixtures.user_fixture()
    blocked_target = AccountsFixtures.user_fixture()

    {:ok, group} =
      Messaging.create_chat_group_conversation(creator.id, %{name: "Blocked Add"}, [])

    {:ok, _block} = Elektrine.Accounts.block_user(blocked_target.id, creator.id)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: creator,
        conversation: %{selected: group},
        ui: %{show_add_members_modal: true}
      }
    }

    assert {:noreply, _updated_socket} =
             MemberOperations.handle_event(
               "add_member_to_conversation",
               %{"user_id" => Integer.to_string(blocked_target.id)},
               socket
             )

    assert Messaging.get_conversation_member(group.id, blocked_target.id) == nil
  end

  test "member management events reject malformed user ids and durations" do
    creator = AccountsFixtures.user_fixture()

    {:ok, group} =
      Messaging.create_chat_group_conversation(creator.id, %{name: "Malformed Members"}, [])

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: creator,
        conversation: %{selected: group},
        ui: %{show_add_members_modal: true}
      }
    }

    assert {:noreply, socket} =
             MemberOperations.handle_event(
               "add_member_to_conversation",
               %{"user_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to add member"

    assert {:noreply, socket} =
             MemberOperations.handle_event("kick_member", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to remove member"

    assert {:noreply, socket} =
             MemberOperations.handle_event("promote_member", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to promote member"

    assert {:noreply, socket} =
             MemberOperations.handle_event("demote_member", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to demote member"

    assert {:noreply, socket} =
             MemberOperations.handle_event(
               "timeout_user",
               %{"user_id" => "12abc", "duration" => "60"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to timeout user"

    assert {:noreply, socket} =
             MemberOperations.handle_event(
               "timeout_user",
               %{"user_id" => Integer.to_string(creator.id), "duration" => "abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to timeout user"

    assert {:noreply, socket} =
             MemberOperations.handle_event("remove_timeout_user", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to remove timeout"
  end

  test "conversation operations reject malformed conversation ids" do
    user = AccountsFixtures.user_fixture()
    socket = conversation_operations_socket(user)

    assert {:noreply, socket} =
             ConversationOperations.handle_event(
               "pin_conversation",
               %{"conversation_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to pin chat"

    assert {:noreply, socket} =
             ConversationOperations.handle_event(
               "unpin_conversation",
               %{"conversation_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to unpin chat"

    assert {:noreply, socket} =
             ConversationOperations.handle_event(
               "mark_as_read",
               %{"conversation_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to mark as read"

    assert {:noreply, socket} =
             ConversationOperations.handle_event(
               "clear_history",
               %{"conversation_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to clear history"

    assert {:noreply, socket} =
             ConversationOperations.handle_event(
               "delete_conversation",
               %{"conversation_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to delete chat"

    assert {:noreply, socket} =
             ConversationOperations.handle_event(
               "leave_conversation",
               %{"conversation_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to leave chat"
  end

  test "message operations reject malformed message ids" do
    user = AccountsFixtures.user_fixture()

    {:ok, group} =
      Messaging.create_chat_group_conversation(user.id, %{name: "Malformed Messages"}, [])

    socket = message_operations_socket(user, group)

    assert {:noreply, socket} =
             MessageOperations.handle_event(
               "react_to_message",
               %{"message_id" => "12abc", "emoji" => "👍"},
               socket
             )

    assert socket.assigns.flash == %{}

    assert {:noreply, socket} =
             MessageOperations.handle_event("delete_message", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to delete message"

    assert {:noreply, socket} =
             MessageOperations.handle_event(
               "delete_message_admin",
               %{"message_id" => "12abc"},
               %{
                 socket
                 | assigns:
                     socket.assigns
                     |> Map.put(:current_user, %{user | is_admin: true})
                     |> Map.put(:selected_conversation, group)
               }
             )

    assert socket.assigns.flash["error"] == "Failed to delete message"

    assert {:noreply, socket} =
             MessageOperations.handle_event(
               "reply_to_message",
               %{"message_id" => "12abc"},
               socket
             )

    assert socket.assigns.message.reply_to == nil

    assert {:noreply, _socket} =
             MessageOperations.handle_event("copy_message", %{"message_id" => "12abc"}, socket)

    assert {:noreply, socket} =
             MessageOperations.handle_event("pin_message", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to pin message"

    assert {:noreply, socket} =
             MessageOperations.handle_event("unpin_message", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to unpin message"
  end

  test "direct message operations reject malformed user ids" do
    user = AccountsFixtures.user_fixture()
    socket = direct_message_operations_socket(user)

    assert {:noreply, socket} =
             DirectMessageOperations.handle_event("start_dm", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to start chat"

    assert {:noreply, socket} =
             DirectMessageOperations.handle_event("block_user", %{"user_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to block user"

    assert {:noreply, socket} =
             DirectMessageOperations.handle_event(
               "unblock_user",
               %{"user_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to unblock user"

    assert {:noreply, socket} =
             DirectMessageOperations.handle_event(
               "show_user_profile",
               %{"user_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "User not found"
  end

  test "context menu operations ignore malformed ids" do
    socket = context_menu_socket()

    assert {:noreply, socket} =
             ContextMenuOperations.handle_event(
               "show_context_menu",
               %{"conversation_id" => "12abc", "x" => 10, "y" => 20},
               socket
             )

    assert socket.assigns.context_menu.conversation == nil
    assert socket.assigns.context_menu.position == %{x: 10, y: 20}

    assert {:noreply, socket} =
             ContextMenuOperations.handle_event(
               "show_message_context_menu",
               %{"message_id" => "12abc", "selected_text" => " selected "},
               socket
             )

    assert socket.assigns.context_menu.message == nil
    assert socket.assigns.context_menu.selected_text == nil
  end

  test "chat index handle_info rejects malformed component ids" do
    user = AccountsFixtures.user_fixture()
    socket = index_info_socket(user)

    assert {:noreply, socket} = Index.handle_info({:start_dm, "12abc"}, socket)
    assert socket.assigns.flash["error"] == "Failed to start chat"

    assert {:noreply, socket} = Index.handle_info({:toggle_user_selection, "12abc"}, socket)
    assert socket.assigns.form.selected_users == []

    assert {:noreply, socket} =
             Index.handle_info({:react_to_message, "12abc", "👍"}, socket)

    assert socket.assigns.message.reply_to == nil

    assert {:noreply, socket} = Index.handle_info({:reply_to_message, "12abc"}, socket)
    assert socket.assigns.message.reply_to == nil
  end

  test "chat UI operations reject malformed report and image ids" do
    socket = chat_ui_socket()

    assert {:noreply, socket} =
             ChatUIOperations.handle_event(
               "show_report_modal",
               %{"type" => "message", "id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Invalid report target"

    assert {:noreply, socket} =
             ChatUIOperations.handle_event(
               "open_image_modal",
               %{"images" => "not-json", "index" => "0"},
               socket
             )

    assert socket.assigns.flash["error"] == "Unable to open image"

    assert {:noreply, socket} =
             ChatUIOperations.handle_event(
               "open_image_modal",
               %{
                 "images" => Jason.encode!(["/ok.png"]),
                 "index" => "0",
                 "message_id" => "12abc"
               },
               socket
             )

    assert socket.assigns.show_image_modal == true
    assert socket.assigns.modal_post == nil
  end

  test "group and channel operations reject malformed ids" do
    user = AccountsFixtures.user_fixture()
    socket = group_channel_socket(user)

    assert {:noreply, socket} =
             GroupChannelOperations.handle_event(
               "toggle_user_selection",
               %{"user_id" => "12abc"},
               socket
             )

    assert socket.assigns.form.selected_users == []

    assert {:noreply, socket} =
             GroupChannelOperations.handle_event("join_group", %{"group_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Failed to join chat"

    assert {:noreply, socket} =
             GroupChannelOperations.handle_event(
               "filter_server",
               %{"server_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Invalid server"

    assert {:noreply, socket} =
             GroupChannelOperations.handle_event(
               "select_server",
               %{"server_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Invalid server"

    assert {:noreply, socket} =
             GroupChannelOperations.handle_event(
               "join_server",
               %{"server_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Invalid server"
  end

  defp chat_socket(user, conversation, opts) do
    messages = Keyword.get(opts, :messages, [])
    conversations = Messaging.list_chat_conversations(user.id)

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        active_server_id: nil,
        current_user: user,
        conversation: %{
          list: conversations,
          filtered: conversations,
          selected: conversation,
          unread_count: 0,
          unread_counts: %{},
          last_message_read_status: %{}
        },
        messages: messages,
        message: %{
          new_message: "",
          reply_to: nil,
          loading_messages: false,
          read_status: %{}
        },
        search: %{conversation_query: ""}
      }
    }
  end

  defp message_operations_socket(user, conversation) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        conversation: %{selected: conversation},
        selected_conversation: conversation,
        messages: [],
        message: %{reply_to: nil},
        context_menu: %{message: %{id: 1}, selected_text: nil},
        moderation: %{user_timeout_status: %{}}
      }
    }
  end

  defp conversation_operations_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        conversation: %{
          list: [],
          filtered: [],
          selected: nil,
          unread_count: 0,
          unread_counts: %{}
        },
        context_menu: %{conversation: %{id: 1}},
        first_unread_message_id: nil
      }
    }
  end

  defp direct_message_operations_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        ui: %{show_new_chat: true, show_profile_modal: true},
        search: %{query: "", results: []}
      }
    }
  end

  defp context_menu_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        context_menu: %{
          conversation: %{id: 1},
          message: %{id: 1},
          selected_text: nil,
          position: nil
        },
        conversation: %{list: [%{id: 1}]},
        messages: [%{id: 1}]
      }
    }
  end

  defp index_info_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        ui: %{show_new_chat: true, show_profile_modal: true},
        search: %{query: "", results: [%{id: 1}]},
        form: %{selected_users: []},
        messages: [%{id: 1}],
        message: %{reply_to: nil}
      }
    }
  end

  defp chat_ui_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        ui: %{show_emoji_picker: false},
        context_menu: %{conversation: nil, message: nil, selected_text: nil},
        messages: [%{id: 1, media_urls: ["/one.png"]}],
        show_mobile_search: false,
        show_report_modal: false,
        modal_images: [],
        modal_image_index: 0
      }
    }
  end

  defp group_channel_socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        form: %{selected_users: []},
        conversation: %{list: [], filtered: [], selected: nil},
        search: %{conversation_query: ""},
        ui: %{show_browse_modal: true},
        active_server_id: nil
      }
    }
  end

  defp device_attrs(device_id) do
    %{
      "device_id" => device_id,
      "public_key" => %{
        "version" => 1,
        "algorithm" => "RSA-OAEP-SHA256",
        "key" => Base.encode64(:crypto.strong_rand_bytes(64))
      },
      "key_algorithm" => "RSA-OAEP-SHA256",
      "label" => "test browser"
    }
  end

  defp encrypted_payload(key_uid) do
    %{
      "version" => 1,
      "content_algorithm" => "AES-256-GCM",
      "key_uid" => key_uid,
      "iv" => Base.encode64(:crypto.strong_rand_bytes(12)),
      "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48))
    }
  end

  defp key_package(user_id, device_id) do
    %{
      user_id: user_id,
      device_id: device_id,
      wrapped_key: %{
        "version" => 1,
        "key_algorithm" => "RSA-OAEP-SHA256",
        "encrypted_key" => Base.encode64(:crypto.strong_rand_bytes(48))
      }
    }
  end
end
