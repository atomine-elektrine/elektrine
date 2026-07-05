defmodule Elektrine.Messaging.ChatMessagesTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatConversation,
    ChatConversationEncryptionKey,
    ChatConversationKeyRecipient,
    ChatConversationMember,
    ChatEncryptionDevice,
    ChatMessage,
    ChatMessages,
    Federation,
    FederationExtensionEvent,
    Server
  }

  alias Elektrine.Repo

  describe "client-side encrypted messages" do
    test "registers devices and lists active devices for conversation members" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()
      outsider = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)

      assert {:ok, _} =
               Messaging.register_chat_encryption_device(alice.id, device_attrs("alice-device"))

      assert {:ok, _} =
               Messaging.register_chat_encryption_device(bob.id, device_attrs("bob-device"))

      assert {:ok, _} =
               Messaging.register_chat_encryption_device(
                 outsider.id,
                 device_attrs("outsider-device")
               )

      devices = Messaging.list_chat_encryption_devices_for_conversation(conversation.id)

      assert Enum.map(devices, & &1.device_id) == ["alice-device", "bob-device"]
      assert Enum.map(devices, & &1.user_id) == [alice.id, bob.id]
    end

    test "stores browser-encrypted payload, recipients, and client search tokens" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, _} = Messaging.register_chat_encryption_device(alice.id, device_attrs("alice-device"))
      {:ok, _} = Messaging.register_chat_encryption_device(bob.id, device_attrs("bob-device"))

      key_uid = "key-test-123456"
      payload = encrypted_payload(key_uid)
      alice_package = key_package(alice.id, "alice-device")
      bob_package = key_package(bob.id, "bob-device")
      bob_wrapped_key = bob_package.wrapped_key

      assert {:ok, message} =
               Messaging.create_client_encrypted_chat_text_message(conversation.id, alice.id, %{
                 "encrypted_payload" => payload,
                 "key_packages" => [alice_package, bob_package],
                 "search_index" => ["client-token"]
               })

      db_message = Repo.get!(ChatMessage, message.id)
      assert db_message.content == nil
      assert db_message.encrypted_content == nil
      assert db_message.client_encrypted_payload == payload
      assert db_message.search_index == ["client-token"]

      encryption_key =
        Repo.get_by!(ChatConversationEncryptionKey,
          conversation_id: conversation.id,
          key_uid: key_uid
        )

      assert encryption_key.algorithm == "AES-256-GCM"

      assert Repo.aggregate(
               from(r in ChatConversationKeyRecipient,
                 where: r.conversation_key_id == ^encryption_key.id
               ),
               :count
             ) == 2

      assert {:ok, ^bob_wrapped_key} =
               Messaging.get_wrapped_chat_key(conversation.id, bob.id, "bob-device", key_uid)

      assert {:ok, results} =
               Messaging.search_messages_in_conversation(conversation.id, bob.id, "zz",
                 search_tokens: ["client-token"]
               )

      assert Enum.map(results, & &1.id) == [message.id]
    end

    test "rejects key packages for devices outside the conversation" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()
      outsider = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, _} = Messaging.register_chat_encryption_device(alice.id, device_attrs("alice-device"))
      {:ok, _} = Messaging.register_chat_encryption_device(bob.id, device_attrs("bob-device"))

      assert {:ok, _} =
               Messaging.register_chat_encryption_device(
                 outsider.id,
                 device_attrs("outsider-device")
               )

      assert {:error, :invalid_key_recipient} =
               Messaging.create_client_encrypted_chat_text_message(conversation.id, alice.id, %{
                 "encrypted_payload" => encrypted_payload("key-test-123456"),
                 "key_packages" => [key_package(outsider.id, "outsider-device")],
                 "search_index" => ["client-token"]
               })
    end

    test "does not return wrapped keys for revoked devices" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, _} = Messaging.register_chat_encryption_device(alice.id, device_attrs("alice-device"))

      {:ok, device} =
        Messaging.register_chat_encryption_device(bob.id, device_attrs("bob-device"))

      key_uid = "key-test-123456"

      assert {:ok, _message} =
               Messaging.create_client_encrypted_chat_text_message(conversation.id, alice.id, %{
                 "encrypted_payload" => encrypted_payload(key_uid),
                 "key_packages" => [
                   key_package(alice.id, "alice-device"),
                   key_package(bob.id, "bob-device")
                 ],
                 "search_index" => ["client-token"]
               })

      device
      |> ChatEncryptionDevice.changeset(%{revoked_at: Elektrine.Time.utc_now()})
      |> Repo.update!()

      assert {:error, :not_found} =
               Messaging.get_wrapped_chat_key(conversation.id, bob.id, "bob-device", key_uid)
    end
  end

  describe "read state" do
    test "tracks chat last read message using chat read receipts" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, first} = Messaging.create_chat_text_message(conversation.id, alice.id, "first")
      {:ok, second} = Messaging.create_chat_text_message(conversation.id, alice.id, "second")

      assert :ok = ChatMessages.mark_messages_read(conversation.id, bob.id, first.id)
      assert ChatMessages.get_last_read_message_id(conversation.id, bob.id) == first.id
      assert ChatMessages.get_unread_count(conversation.id, bob.id) == 1

      assert :ok = ChatMessages.mark_messages_read(conversation.id, bob.id, second.id)
      assert ChatMessages.get_last_read_message_id(conversation.id, bob.id) == second.id
      assert ChatMessages.get_unread_count(conversation.id, bob.id) == 0
    end

    test "marks group messages read by time when ids are not chronological" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()
      charlie = AccountsFixtures.user_fixture()

      {:ok, group} =
        Messaging.create_chat_group_conversation(alice.id, %{name: "Team"}, [bob.id, charlie.id])

      {:ok, newest} = Messaging.create_chat_text_message(group.id, alice.id, "newest")

      {:ok, older_with_higher_id} =
        Messaging.create_chat_text_message(group.id, charlie.id, "older")

      older_inserted_at = NaiveDateTime.add(newest.inserted_at, -60, :second)

      from(m in ChatMessage, where: m.id == ^older_with_higher_id.id)
      |> Repo.update_all(set: [inserted_at: older_inserted_at])

      assert ChatMessages.get_unread_count(group.id, bob.id) == 2

      assert :ok = ChatMessages.mark_messages_read(group.id, bob.id, newest.id)
      assert ChatMessages.get_unread_count(group.id, bob.id) == 0
    end

    test "marks latest same-timestamp chat messages read" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, first} = Messaging.create_chat_text_message(conversation.id, alice.id, "first")
      {:ok, second} = Messaging.create_chat_text_message(conversation.id, alice.id, "second")

      same_inserted_at = ~N[2026-05-03 02:11:38]

      from(m in ChatMessage, where: m.id in ^[first.id, second.id])
      |> Repo.update_all(set: [inserted_at: same_inserted_at])

      data = Messaging.get_conversation_messages(conversation.id, bob.id, limit: 2)
      assert Enum.map(data.messages, & &1.id) == [second.id, first.id]

      assert {:ok, :read} = Messaging.mark_as_read(conversation.id, bob.id)
      assert ChatMessages.get_unread_count(conversation.id, bob.id) == 0
      assert ChatMessages.get_last_read_message_id(conversation.id, bob.id) == second.id
    end

    test "broadcasts chat unread count for nav badges after marking read" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, message} = Messaging.create_chat_text_message(conversation.id, alice.id, "hello")

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{bob.id}:notification_count")

      assert :ok = ChatMessages.mark_messages_read(conversation.id, bob.id, message.id)
      assert_receive {:chat_unread_count_updated, 0}
    end

    test "clears matching portal notifications when chat messages are read" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, message} = Messaging.create_chat_text_message(conversation.id, alice.id, "hello")

      {:ok, notification} =
        Elektrine.Notifications.create_notification(%{
          user_id: bob.id,
          actor_id: alice.id,
          type: "new_message",
          title: "New message",
          body: "hello",
          source_type: "message",
          source_id: message.id,
          url: Elektrine.Paths.chat_message_path(conversation.id, message.id)
        })

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{bob.id}:notification_count")

      assert :ok = ChatMessages.mark_messages_read(conversation.id, bob.id, message.id)
      assert_receive {:notification_count_updated, 0}

      assert %{read_at: %DateTime{}} =
               Repo.get!(Elektrine.Notifications.Notification, notification.id)
    end
  end

  describe "media URL validation" do
    test "accepts content-addressed chat attachment paths owned by the sender" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)

      hash = String.duplicate("a", 64)
      media_url = "/uploads/chat-attachments/#{alice.id}/aa/aa/aa/#{hash}.png"

      assert {:ok, message} =
               Messaging.create_media_message(conversation.id, alice.id, [media_url], nil)

      assert message.media_urls == [media_url]
    end

    test "rejects content-addressed chat attachment paths owned by another user" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)

      hash = String.duplicate("a", 64)
      media_url = "/uploads/chat-attachments/#{bob.id}/aa/aa/aa/#{hash}.png"

      assert {:error, %Ecto.Changeset{} = changeset} =
               Messaging.create_media_message(conversation.id, alice.id, [media_url], nil)

      assert {"contains untrusted media URLs", _} = changeset.errors[:media_urls]
    end
  end

  describe "blocked direct messages" do
    test "rejects new messages in an existing local DM after a block" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)

      assert {:ok, _message} =
               Messaging.create_chat_text_message(conversation.id, alice.id, "before")

      assert {:ok, _block} = Elektrine.Accounts.block_user(bob.id, alice.id)

      assert {:error, :blocked} =
               Messaging.create_chat_text_message(conversation.id, alice.id, "after")

      assert {:error, :blocked} =
               Messaging.create_chat_text_message(conversation.id, bob.id, "also blocked")

      data = Messaging.get_conversation_messages(conversation.id, bob.id, limit: 10)
      assert Enum.map(data.messages, &ChatMessage.display_content/1) == ["before"]
    end

    test "rejects client-encrypted messages in an existing local DM after a block" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      assert {:ok, _block} = Elektrine.Accounts.block_user(bob.id, alice.id)

      assert {:error, :blocked} =
               Messaging.create_client_encrypted_chat_text_message(conversation.id, alice.id, %{
                 "encrypted_payload" => encrypted_payload("key-blocked-123"),
                 "key_packages" => [key_package(alice.id, "alice-device")],
                 "search_index" => ["blocked-token"]
               })
    end
  end

  describe "clear history" do
    test "hides existing chat messages per user and keeps new messages visible" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)
      {:ok, _first} = Messaging.create_chat_text_message(conversation.id, alice.id, "first")
      {:ok, _second} = Messaging.create_chat_text_message(conversation.id, alice.id, "second")

      assert length(ChatMessages.get_messages(conversation.id, user_id: bob.id)) == 2

      assert {:ok, :cleared} = ChatMessages.clear_history_for_user(conversation.id, bob.id)
      assert ChatMessages.get_messages(conversation.id, user_id: bob.id) == []

      {:ok, fresh} = Messaging.create_chat_text_message(conversation.id, alice.id, "fresh")

      visible_messages = ChatMessages.get_messages(conversation.id, user_id: bob.id)
      assert Enum.map(visible_messages, & &1.id) == [fresh.id]
      assert ChatMessages.get_unread_count(conversation.id, bob.id) == 1
    end
  end

  describe "remote sender hydration" do
    test "hydrates sender metadata for mirrored remote messages" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)

      remote_message =
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          conversation_id: conversation.id,
          sender_id: nil,
          content: "hello from remote",
          message_type: "text",
          is_federated_mirror: true,
          origin_domain: "remote.example",
          media_metadata: %{
            "remote_sender" => %{
              "username" => "remotealice",
              "display_name" => "Remote Alice",
              "domain" => "remote.example"
            }
          }
        })
        |> Repo.insert!()

      hydrated = ChatMessages.get_message_decrypted(remote_message.id)

      assert hydrated.sender.id == nil
      assert hydrated.sender.username == "remotealice"
      assert hydrated.sender.display_name == "Remote Alice"
      assert hydrated.sender.handle == "remotealice@remote.example"
      assert hydrated.sender.remote == true
    end
  end

  describe "link previews" do
    test "attaches pending link previews to chat messages" do
      alice = AccountsFixtures.user_fixture()
      bob = AccountsFixtures.user_fixture()

      {:ok, conversation} = Messaging.create_dm_conversation(alice.id, bob.id)

      preview =
        %Elektrine.Social.LinkPreview{}
        |> Elektrine.Social.LinkPreview.changeset(%{
          url: "https://www.youtube.com/watch?v=_XHp4QZVmoc",
          status: "pending"
        })
        |> Repo.insert!()

      {:ok, message} =
        Messaging.create_chat_text_message(
          conversation.id,
          alice.id,
          preview.url
        )

      message = ChatMessages.get_message(message.id)

      assert message.link_preview_id == preview.id
      assert message.link_preview.id == preview.id
    end
  end

  describe "mirrored channel writes" do
    test "allows local durable writes in mirrored channels" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      mirrored_member_fixture(channel.id, user.id)
      message = mirrored_local_message_fixture(channel.id, user.id)

      assert {:ok, created} = ChatMessages.create_text_message(channel.id, user.id, "hello")
      assert created.conversation_id == channel.id

      assert {:ok, edited} = ChatMessages.edit_message(message.id, user.id, "edited")
      assert edited.content == "edited"

      assert {:ok, reaction} = ChatMessages.add_reaction(message.id, user.id, "👍")
      assert reaction.emoji == "👍"

      assert {:ok, 1} = ChatMessages.remove_reaction(message.id, user.id, "👍")

      assert {:ok, deleted} = ChatMessages.delete_message(message.id, user.id)
      assert not is_nil(deleted.deleted_at)
    end

    test "tracks read state in mirrored channels" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      mirrored_member_fixture(channel.id, user.id)
      message = mirrored_local_message_fixture(channel.id, user.id)

      assert :ok = ChatMessages.mark_messages_read(channel.id, user.id, message.id)
      assert ChatMessages.get_last_read_message_id(channel.id, user.id) == message.id
    end

    test "enforces federated role assignments and permission overwrites for local writes" do
      user = AccountsFixtures.user_fixture()
      channel = mirrored_channel_fixture()
      mirrored_member_fixture(channel.id, user.id, "readonly")
      actor_uri = Elektrine.Messaging.Federation.Utils.sender_payload(user)["uri"]

      insert_extension_event(
        channel.id,
        "role.upsert",
        "role:speaker:channel:#{channel.id}",
        %{
          "role" => %{
            "id" => "role:speaker",
            "name" => "Speaker",
            "permissions" => ["send_messages"],
            "position" => 20
          }
        }
      )

      insert_extension_event(
        channel.id,
        "role.assignment.upsert",
        "role_assignment:role:speaker:member:#{actor_uri}:channel:#{channel.id}",
        %{
          "assignment" => %{
            "role_id" => "role:speaker",
            "target" => %{"type" => "member", "id" => actor_uri},
            "state" => "assigned"
          }
        }
      )

      assert {:ok, _message} =
               ChatMessages.create_text_message(channel.id, user.id, "federated role allows send")

      insert_extension_event(
        channel.id,
        "permission.overwrite.upsert",
        "overwrite:deny-send:channel:#{channel.id}",
        %{
          "overwrite" => %{
            "id" => "deny-send",
            "target" => %{"type" => "member", "id" => actor_uri},
            "allow" => [],
            "deny" => ["send_messages"]
          }
        }
      )

      assert {:error, :unauthorized} =
               ChatMessages.create_text_message(channel.id, user.id, "blocked by overwrite")
    end
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

  defp mirrored_channel_fixture do
    suffix = System.unique_integer([:positive])

    server =
      %Server{}
      |> Server.changeset(%{
        name: "Remote Server #{suffix}",
        description: "Federated mirror server",
        federation_id: "https://remote.example/_arblarg/servers/#{suffix}",
        origin_domain: "remote.example",
        is_federated_mirror: true
      })
      |> Repo.insert!()

    %ChatConversation{}
    |> ChatConversation.channel_changeset(%{
      name: "remote-channel-#{suffix}",
      description: "Mirrored remote channel",
      server_id: server.id,
      federated_source: "https://remote.example/_arblarg/channels/#{suffix}",
      is_federated_mirror: true
    })
    |> Repo.insert!()
  end

  defp mirrored_local_message_fixture(conversation_id, sender_id) do
    %ChatMessage{}
    |> ChatMessage.changeset(%{
      conversation_id: conversation_id,
      sender_id: sender_id,
      content: "seed message",
      message_type: "text"
    })
    |> Repo.insert!()
  end

  defp mirrored_member_fixture(conversation_id, user_id, role \\ "member") do
    %ChatConversationMember{}
    |> ChatConversationMember.changeset(%{
      conversation_id: conversation_id,
      user_id: user_id,
      role: role,
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_extension_event(conversation_id, event_type, event_key, payload) do
    canonical_event_type = ArblargSDK.canonical_event_type(event_type)

    %FederationExtensionEvent{}
    |> FederationExtensionEvent.changeset(%{
      event_type: canonical_event_type,
      origin_domain: Federation.local_domain(),
      event_key: event_key,
      payload: payload,
      occurred_at: DateTime.utc_now(),
      conversation_id: conversation_id
    })
    |> Repo.insert!()
  end
end
