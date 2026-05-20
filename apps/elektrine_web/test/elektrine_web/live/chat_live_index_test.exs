defmodule ElektrineWeb.ChatLiveIndexTest do
  use Elektrine.DataCase, async: false

  alias ArblargWeb.ChatLive.Index
  alias ArblargWeb.ChatLive.Operations.MemberOperations
  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  test "mount redirects instead of crashing when current_user is missing" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:ok, updated_socket} = Index.mount(%{}, %{}, socket)
    assert {:redirect, %{to: "/login"}} = updated_socket.redirected
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
