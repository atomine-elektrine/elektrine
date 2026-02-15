defmodule Elektrine.Messaging.MessagesMentionsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Messaging
  alias Elektrine.Notifications

  describe "chat mention notifications" do
    setup do
      sender = user_fixture()
      mentioned = user_fixture()
      restricted = user_fixture()

      {:ok, conversation} =
        Messaging.create_group_conversation(
          sender.id,
          %{name: "mention-group-#{System.unique_integer([:positive])}"},
          [mentioned.id, restricted.id]
        )

      %{sender: sender, mentioned: mentioned, restricted: restricted, conversation: conversation}
    end

    test "creates mention notifications for mentioned conversation members", %{
      sender: sender,
      mentioned: mentioned,
      conversation: conversation
    } do
      {:ok, message} =
        Messaging.create_text_message(
          conversation.id,
          sender.id,
          "hello @#{mentioned.username}"
        )

      mention_notifications =
        Notifications.list_notifications(mentioned.id)
        |> Enum.filter(&(&1.type == "mention"))

      assert Enum.any?(mention_notifications, &(&1.source_id == message.id))
    end

    test "respects mention privacy preferences", %{
      sender: sender,
      restricted: restricted,
      conversation: conversation
    } do
      {:ok, _} = Accounts.block_user(restricted.id, sender.id)

      {:ok, _message} =
        Messaging.create_text_message(
          conversation.id,
          sender.id,
          "hello @#{restricted.username}"
        )

      restricted_mentions =
        Notifications.list_notifications(restricted.id)
        |> Enum.filter(&(&1.type == "mention"))

      assert restricted_mentions == []
    end
  end
end
