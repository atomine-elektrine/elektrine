defmodule Elektrine.Messaging.ChatMessagesTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.{ChatMessage, ChatMessages}
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
end
