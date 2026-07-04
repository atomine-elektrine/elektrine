defmodule Elektrine.Messaging.ChatWebhooksTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Messaging.ChatWebhook
  alias Elektrine.Messaging.ChatWebhooks
  alias Elektrine.Messaging.RateLimiter
  alias Elektrine.Repo

  defp create_server_channel_with_member do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "hook-space", is_public: true})
    {:ok, _member} = Messaging.join_server(server.id, member.id)

    [channel | _] = server.channels

    %{owner: owner, member: member, server: server, channel: channel}
  end

  defp create_webhook!(conversation_id, user_id, attrs \\ %{}) do
    {:ok, webhook} =
      ChatWebhooks.create_webhook(
        conversation_id,
        user_id,
        Map.merge(%{"name" => "Deploy Bot"}, attrs)
      )

    webhook
  end

  describe "create_webhook/3" do
    test "server owner can create a webhook and receives the plaintext token once" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      assert {:ok, webhook} =
               ChatWebhooks.create_webhook(channel.id, owner.id, %{"name" => "Deploy Bot"})

      assert webhook.name == "Deploy Bot"
      assert webhook.active
      assert webhook.creator_id == owner.id
      assert is_binary(webhook.token)
      assert String.starts_with?(webhook.token, "ewh_")

      # The token is stored only as a hash; the plaintext is not retrievable.
      reloaded = Repo.get(ChatWebhook, webhook.id)
      assert reloaded.token == nil
      assert reloaded.token_hash == ChatWebhook.hash_token(webhook.token)
      refute reloaded.token_hash == webhook.token
    end

    test "regular channel members cannot create webhooks" do
      %{member: member, channel: channel} = create_server_channel_with_member()

      assert {:error, :unauthorized} =
               ChatWebhooks.create_webhook(channel.id, member.id, %{"name" => "Nope"})
    end

    test "group owners can create webhooks, group members cannot" do
      creator = AccountsFixtures.user_fixture()
      buddy = AccountsFixtures.user_fixture()

      {:ok, group} =
        Messaging.create_chat_group_conversation(creator.id, %{name: "hook group"}, [buddy.id])

      assert {:error, :unauthorized} =
               ChatWebhooks.create_webhook(group.id, buddy.id, %{"name" => "Nope"})

      assert {:ok, webhook} =
               ChatWebhooks.create_webhook(group.id, creator.id, %{"name" => "Group Bot"})

      assert webhook.conversation_id == group.id
    end

    test "webhooks cannot be created on DMs" do
      user_a = AccountsFixtures.user_fixture()
      user_b = AccountsFixtures.user_fixture()

      {:ok, dm} = Messaging.create_dm_conversation(user_a.id, user_b.id)

      assert {:error, :unsupported_conversation} =
               ChatWebhooks.create_webhook(dm.id, user_a.id, %{"name" => "Nope"})
    end

    test "enforces the per-conversation webhook cap" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      for index <- 1..ChatWebhooks.max_webhooks_per_conversation() do
        create_webhook!(channel.id, owner.id, %{"name" => "hook #{index}"})
      end

      assert {:error, :webhook_limit_reached} =
               ChatWebhooks.create_webhook(channel.id, owner.id, %{"name" => "one too many"})
    end
  end

  describe "management" do
    test "list_webhooks requires manage_webhooks" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:ok, [listed]} = ChatWebhooks.list_webhooks(channel.id, owner.id)
      assert listed.id == webhook.id
      assert listed.token == nil

      assert {:error, :unauthorized} = ChatWebhooks.list_webhooks(channel.id, member.id)
    end

    test "update_webhook renames and updates avatar" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:error, :unauthorized} =
               ChatWebhooks.update_webhook(webhook.id, member.id, %{"name" => "Hijack"})

      assert {:ok, updated} =
               ChatWebhooks.update_webhook(webhook.id, owner.id, %{
                 "name" => "Renamed Bot",
                 "avatar_url" => "https://i.imgur.com/bot.png"
               })

      assert updated.name == "Renamed Bot"
      assert updated.avatar_url == "https://i.imgur.com/bot.png"
    end

    test "rotate_webhook_token invalidates the old token" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)
      old_token = webhook.token

      assert {:error, :unauthorized} = ChatWebhooks.rotate_webhook_token(webhook.id, member.id)

      assert {:ok, rotated} = ChatWebhooks.rotate_webhook_token(webhook.id, owner.id)
      assert is_binary(rotated.token)
      refute rotated.token == old_token

      assert {:error, :not_found} =
               ChatWebhooks.execute_webhook(webhook.id, old_token, %{"content" => "hi"})

      assert {:ok, _message} =
               ChatWebhooks.execute_webhook(webhook.id, rotated.token, %{"content" => "hi"})
    end

    test "deactivate and delete require manage_webhooks" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:error, :unauthorized} = ChatWebhooks.deactivate_webhook(webhook.id, member.id)
      assert {:error, :unauthorized} = ChatWebhooks.delete_webhook(webhook.id, member.id)

      assert {:ok, deactivated} = ChatWebhooks.deactivate_webhook(webhook.id, owner.id)
      refute deactivated.active

      assert {:ok, _deleted} = ChatWebhooks.delete_webhook(webhook.id, owner.id)
      refute Repo.get(ChatWebhook, webhook.id)
    end
  end

  describe "execute_webhook/3" do
    test "posts a message with webhook display metadata and broadcasts it" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook =
        create_webhook!(channel.id, owner.id, %{
          "name" => "Deploy Bot",
          "avatar_url" => "https://i.imgur.com/bot.png"
        })

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      assert {:ok, message} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{
                 "content" => "build passed"
               })

      assert message.conversation_id == channel.id
      assert message.sender_id == nil
      assert message.webhook_id == webhook.id
      assert message.content == "build passed"
      assert message.media_metadata["webhook_sender"]["name"] == "Deploy Bot"

      # Hydrated sender renders like a user and carries badge flags.
      assert message.sender.username == "Deploy Bot"
      assert message.sender.avatar == "https://i.imgur.com/bot.png"
      assert message.sender.webhook == true
      assert message.sender.is_bot == true

      message_id = message.id
      assert_receive {:new_chat_message, %ChatMessage{id: ^message_id} = broadcast}
      assert broadcast.sender.username == "Deploy Bot"
      assert broadcast.sender.webhook == true
    end

    test "applies username and avatar overrides" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:ok, message} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{
                 "content" => "override me",
                 "username" => "Release Notes",
                 "avatar_url" => "https://i.imgur.com/other.png"
               })

      assert message.media_metadata["webhook_sender"]["name"] == "Release Notes"

      assert message.media_metadata["webhook_sender"]["avatar_url"] ==
               "https://i.imgur.com/other.png"

      assert message.sender.username == "Release Notes"
      assert message.sender.avatar == "https://i.imgur.com/other.png"
    end

    test "rejects oversize overrides" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:error, :invalid_override} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{
                 "content" => "hello",
                 "username" => String.duplicate("x", 81)
               })
    end

    test "returns not_found for unknown ids and bad tokens alike" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:error, :not_found} =
               ChatWebhooks.execute_webhook(webhook.id + 1_000_000, webhook.token, %{
                 "content" => "hi"
               })

      assert {:error, :not_found} =
               ChatWebhooks.execute_webhook(webhook.id, "ewh_wrong-token", %{"content" => "hi"})

      assert {:error, :not_found} =
               ChatWebhooks.execute_webhook(webhook.id, nil, %{"content" => "hi"})
    end

    test "rejects inactive webhooks" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)
      {:ok, _} = ChatWebhooks.deactivate_webhook(webhook.id, owner.id)

      assert {:error, :webhook_inactive} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{"content" => "hi"})
    end

    test "rejects empty and oversize content" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      assert {:error, :invalid_content} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{"content" => "   "})

      assert {:error, :invalid_content} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{})

      assert {:error, :invalid_content} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{
                 "content" => String.duplicate("a", 4001)
               })
    end

    test "rate limits executions per webhook" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      webhook = create_webhook!(channel.id, owner.id)

      for _ <- 1..30, do: RateLimiter.record_webhook_execution(webhook.id)

      assert {:error, :rate_limited} =
               ChatWebhooks.execute_webhook(webhook.id, webhook.token, %{"content" => "hi"})
    end
  end
end
