defmodule Elektrine.Messaging.ChatMessagePinsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Messaging.ChatMessagePin
  alias Elektrine.Messaging.ChatMessagePins
  alias Elektrine.Repo

  defp create_server_channel_with_member do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "pin-space", is_public: true})
    {:ok, _member} = Messaging.join_server(server.id, member.id)

    [channel | _] = server.channels

    %{owner: owner, member: member, server: server, channel: channel}
  end

  defp create_message!(conversation_id, sender_id, content) do
    {:ok, message} = Messaging.create_chat_text_message(conversation_id, sender_id, content)
    message
  end

  describe "pin_message/2" do
    test "server owner can pin a message in a server channel" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "pin me")

      assert {:ok, pinned} = ChatMessagePins.pin_message(message.id, owner.id)
      assert pinned.is_pinned
      assert pinned.pinned_by_id == owner.id
      assert %DateTime{} = pinned.pinned_at

      assert Repo.get_by(ChatMessagePin,
               message_id: message.id,
               conversation_id: channel.id,
               pinned_by_id: owner.id
             )
    end

    test "regular channel members cannot pin" do
      %{member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "not yours to pin")

      assert {:error, :unauthorized} = ChatMessagePins.pin_message(message.id, member.id)
    end

    test "pinning twice returns already_pinned" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "once only")

      assert {:ok, _} = ChatMessagePins.pin_message(message.id, owner.id)
      assert {:error, :already_pinned} = ChatMessagePins.pin_message(message.id, owner.id)
    end

    test "unknown messages return not_found" do
      %{owner: owner} = create_server_channel_with_member()

      assert {:error, :not_found} = ChatMessagePins.pin_message(-1, owner.id)
    end

    test "group admins can pin, group members cannot" do
      creator = AccountsFixtures.user_fixture()
      buddy = AccountsFixtures.user_fixture()

      {:ok, group} =
        Messaging.create_chat_group_conversation(creator.id, %{name: "pin group"}, [buddy.id])

      message = create_message!(group.id, buddy.id, "group pin")

      assert {:error, :unauthorized} = ChatMessagePins.pin_message(message.id, buddy.id)
      assert {:ok, pinned} = ChatMessagePins.pin_message(message.id, creator.id)
      assert pinned.is_pinned
    end

    test "enforces the per-conversation pin cap" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      limit = ChatMessagePins.max_pins_per_conversation()

      for index <- 1..limit do
        message = create_message!(channel.id, member.id, "filler #{index}")

        Repo.insert!(%ChatMessagePin{
          conversation_id: channel.id,
          message_id: message.id,
          pinned_by_id: owner.id
        })
      end

      over_limit = create_message!(channel.id, member.id, "one too many")

      assert {:error, :pin_limit_reached} = ChatMessagePins.pin_message(over_limit.id, owner.id)
    end

    test "broadcasts a pin event on the conversation topic" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "broadcast me")

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      assert {:ok, _} = ChatMessagePins.pin_message(message.id, owner.id)

      message_id = message.id
      assert_receive {:message_pinned, %ChatMessage{id: ^message_id, is_pinned: true}}
    end
  end

  describe "unpin_message/2" do
    test "server owner can unpin and unpinning clears the pin row" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "temporary pin")
      {:ok, _} = ChatMessagePins.pin_message(message.id, owner.id)

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      assert {:ok, unpinned} = ChatMessagePins.unpin_message(message.id, owner.id)
      refute unpinned.is_pinned
      refute Repo.get_by(ChatMessagePin, message_id: message.id)

      message_id = message.id
      assert_receive {:message_unpinned, %ChatMessage{id: ^message_id, is_pinned: false}}
    end

    test "unpinning a message that is not pinned returns not_pinned" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "never pinned")

      assert {:error, :not_pinned} = ChatMessagePins.unpin_message(message.id, owner.id)
    end

    test "regular members cannot unpin" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "sticky")
      {:ok, _} = ChatMessagePins.pin_message(message.id, owner.id)

      assert {:error, :unauthorized} = ChatMessagePins.unpin_message(message.id, member.id)
      assert Repo.get_by(ChatMessagePin, message_id: message.id)
    end
  end

  describe "list_pinned_messages/1" do
    test "returns pinned messages newest pin first" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      first = create_message!(channel.id, member.id, "first pinned")
      second = create_message!(channel.id, member.id, "second pinned")
      _unpinned = create_message!(channel.id, member.id, "not pinned")

      {:ok, _} = ChatMessagePins.pin_message(first.id, owner.id)
      {:ok, _} = ChatMessagePins.pin_message(second.id, owner.id)

      pinned = ChatMessagePins.list_pinned_messages(channel.id)

      assert Enum.map(pinned, & &1.id) == [second.id, first.id]
      assert Enum.all?(pinned, & &1.is_pinned)
      assert Enum.all?(pinned, &(&1.pinned_by_id == owner.id))
    end

    test "excludes deleted messages" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      message = create_message!(channel.id, member.id, "will be deleted")
      {:ok, _} = ChatMessagePins.pin_message(message.id, owner.id)
      {:ok, _} = Messaging.delete_chat_message(message.id, member.id)

      assert ChatMessagePins.list_pinned_messages(channel.id) == []
    end
  end

  describe "pin state hydration" do
    test "get_chat_messages returns pin state on loaded messages" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      pinned_message = create_message!(channel.id, member.id, "hydrate me")
      plain_message = create_message!(channel.id, member.id, "plain")

      {:ok, _} = ChatMessagePins.pin_message(pinned_message.id, owner.id)

      messages = Messaging.get_chat_messages(channel.id, user_id: member.id)
      by_id = Map.new(messages, &{&1.id, &1})

      assert by_id[pinned_message.id].is_pinned
      assert by_id[pinned_message.id].pinned_by_id == owner.id
      refute by_id[plain_message.id].is_pinned
    end
  end
end
