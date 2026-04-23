defmodule Elektrine.Messaging.ChatMessagesTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatConversation,
    ChatConversationMember,
    ChatMessage,
    ChatMessages,
    Federation,
    FederationExtensionEvent,
    Server
  }

  alias Elektrine.Repo

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
