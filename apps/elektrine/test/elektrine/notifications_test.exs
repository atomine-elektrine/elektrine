defmodule Elektrine.NotificationsTest do
  use Elektrine.DataCase, async: true

  import Ecto.Query
  alias Elektrine.{Accounts, Messaging, Notifications, Repo}
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging.Message
  alias Elektrine.Notifications.FederationNotifications
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  describe "notification preferences" do
    setup do
      user = user_fixture()
      follower = user_fixture()
      {:ok, user: user, follower: follower}
    end

    test "notify_follow respects user's notify_on_new_follower preference", %{
      user: user,
      follower: follower
    } do
      # Default should be true, so notification should be created
      assert {:ok, notification} = Notifications.notify_follow(user.id, follower)
      assert notification.type == "follow"
      assert notification.user_id == user.id

      # Disable follow notifications
      {:ok, updated_user} = Accounts.update_user(user, %{notify_on_new_follower: false})
      assert updated_user.notify_on_new_follower == false

      # Now notification should not be created
      assert {:ok, :notification_disabled} = Notifications.notify_follow(user.id, follower)

      # Verify no new notification was created
      notifications = Notifications.list_notifications(user.id)
      # Only the first one
      assert length(notifications) == 1
    end

    test "notify_new_message respects user's notify_on_direct_message preference", %{
      user: user,
      follower: sender
    } do
      # Default should be true, so notification should be created
      assert {:ok, notification} =
               Notifications.notify_new_message(
                 user.id,
                 sender,
                 "test-conversation",
                 "Hello there!"
               )

      assert notification.type == "new_message"
      assert notification.user_id == user.id

      # Disable message notifications
      {:ok, updated_user} = Accounts.update_user(user, %{notify_on_direct_message: false})
      assert updated_user.notify_on_direct_message == false

      # Now notification should not be created
      assert {:ok, :notification_disabled} =
               Notifications.notify_new_message(
                 user.id,
                 sender,
                 "test-conversation",
                 "Another message"
               )

      # Verify no new notification was created
      notifications = Notifications.list_notifications(user.id)
      # Only the first one
      assert length(notifications) == 1
    end

    test "notify_mention respects user's notify_on_mention preference", %{
      user: user,
      follower: actor
    } do
      # Default should be true, so notification should be created
      assert {:ok, notification} =
               Notifications.notify_mention(
                 user.id,
                 actor,
                 "post",
                 123,
                 "Hey @#{user.username}, check this out!"
               )

      assert notification.type == "mention"
      assert notification.user_id == user.id

      # Disable mention notifications
      {:ok, updated_user} = Accounts.update_user(user, %{notify_on_mention: false})
      assert updated_user.notify_on_mention == false

      # Now notification should not be created
      assert {:ok, :notification_disabled} =
               Notifications.notify_mention(
                 user.id,
                 actor,
                 "post",
                 456,
                 "Another mention @#{user.username}"
               )

      # Verify no new notification was created
      notifications = Notifications.list_notifications(user.id)
      # Only the first one
      assert length(notifications) == 1
    end

    test "default notification preferences are true", %{user: user} do
      assert user.notify_on_new_follower == true
      assert user.notify_on_direct_message == true
      assert user.notify_on_mention == true
    end
  end

  describe "notification creation and retrieval" do
    setup do
      user = user_fixture()
      {:ok, user: user}
    end

    test "create_notification creates a notification", %{user: user} do
      attrs = %{
        type: "system",
        title: "Test Notification",
        body: "This is a test",
        url: "/test",
        icon: "hero-bell",
        user_id: user.id,
        priority: "normal"
      }

      assert {:ok, notification} = Notifications.create_notification(attrs)
      assert notification.type == "system"
      assert notification.title == "Test Notification"
      assert notification.user_id == user.id
    end

    test "list_notifications returns notifications for user", %{user: user} do
      # Create some notifications
      {:ok, _n1} =
        Notifications.create_notification(%{
          type: "system",
          title: "First",
          user_id: user.id
        })

      # Add a small delay to ensure different timestamps
      Process.sleep(100)

      {:ok, _n2} =
        Notifications.create_notification(%{
          type: "system",
          title: "Second",
          user_id: user.id
        })

      notifications = Notifications.list_notifications(user.id)
      assert length(notifications) == 2
      # Verify both notifications are present
      titles = Enum.map(notifications, & &1.title)
      assert "First" in titles
      assert "Second" in titles
    end

    test "get_unread_count returns correct count", %{user: user} do
      # Create some notifications
      {:ok, n1} =
        Notifications.create_notification(%{
          type: "system",
          title: "First",
          user_id: user.id
        })

      {:ok, _n2} =
        Notifications.create_notification(%{
          type: "system",
          title: "Second",
          user_id: user.id
        })

      assert Notifications.get_unread_count(user.id) == 2

      # Mark one as read
      Notifications.mark_as_read(n1.id, user.id)
      assert Notifications.get_unread_count(user.id) == 1
    end

    test "mark_all_as_read marks all notifications as read", %{user: user} do
      # Create notifications
      {:ok, _} =
        Notifications.create_notification(%{
          type: "system",
          title: "First",
          user_id: user.id
        })

      {:ok, _} =
        Notifications.create_notification(%{
          type: "system",
          title: "Second",
          user_id: user.id
        })

      assert Notifications.get_unread_count(user.id) == 2

      # Mark all as read
      Notifications.mark_all_as_read(user.id)
      assert Notifications.get_unread_count(user.id) == 0
    end
  end

  describe "chat notification delivery" do
    test "direct message notifications are still delivered when the preference is nil" do
      sender = user_fixture()
      recipient = user_fixture()

      from(u in User, where: u.id == ^recipient.id)
      |> Repo.update_all(set: [notify_on_direct_message: nil])

      assert {:ok, conversation} = Messaging.create_dm_conversation(sender.id, recipient.id)
      assert {:ok, message} = Messaging.create_text_message(conversation.id, sender.id, "hello")

      notifications = Notifications.list_notifications(recipient.id)

      assert Enum.any?(notifications, fn notification ->
               notification.type == "new_message" and notification.source_id == message.id
             end)
    end
  end

  describe "message notification urls" do
    setup do
      user = user_fixture()
      parent_post = post_fixture(user: user)
      remote_actor = remote_actor_fixture()
      remote_reply = federated_reply_fixture(parent_post, remote_actor)

      {:ok,
       user: user,
       parent_post: parent_post,
       remote_actor: remote_actor,
       remote_reply: remote_reply}
    end

    test "list_notifications rewrites legacy fediverse reply and mention urls", %{
      user: user,
      parent_post: parent_post,
      remote_reply: remote_reply
    } do
      {:ok, reply_notification} =
        Notifications.create_notification(%{
          user_id: user.id,
          type: "reply",
          title: "Reply from the fediverse",
          body: "Legacy reply notification",
          url: "/timeline/post/#{remote_reply.id}",
          source_type: "message",
          source_id: remote_reply.id,
          priority: "normal"
        })

      {:ok, mention_notification} =
        Notifications.create_notification(%{
          user_id: user.id,
          type: "mention",
          title: "Mentioned in a post",
          body: "Legacy mention notification",
          source_type: "message",
          source_id: remote_reply.id,
          priority: "normal"
        })

      notifications = Notifications.list_notifications(user.id)

      expected_url = "/remote/post/#{parent_post.id}#message-#{remote_reply.id}"

      assert Enum.find(notifications, &(&1.id == reply_notification.id)).url == expected_url
      assert Enum.find(notifications, &(&1.id == mention_notification.id)).url == expected_url
    end

    test "new fediverse reply and mention notifications store canonical thread urls", %{
      user: user,
      parent_post: parent_post,
      remote_actor: remote_actor,
      remote_reply: remote_reply
    } do
      expected_url = "/remote/post/#{parent_post.id}#message-#{remote_reply.id}"

      assert {:ok, reply_notification} =
               FederationNotifications.notify_remote_reply(remote_reply.id, remote_actor.id)

      assert {:ok, mention_notification} =
               FederationNotifications.notify_remote_mention(
                 user.id,
                 remote_reply.id,
                 remote_actor.id
               )

      assert reply_notification.url == expected_url
      assert mention_notification.url == expected_url
    end
  end

  defp remote_actor_fixture do
    {:ok, actor} =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://poa.st/users/waifupoaster#{System.unique_integer([:positive])}",
        username: "waifupoaster#{System.unique_integer([:positive])}",
        domain: "poa.st",
        inbox_url: "https://poa.st/inbox",
        public_key: "test-public-key"
      })
      |> Repo.insert()

    actor
  end

  defp federated_reply_fixture(parent_post, remote_actor) do
    {:ok, reply} =
      %Message{}
      |> Message.federated_changeset(%{
        content: "Remote reply",
        visibility: "public",
        post_type: "post",
        activitypub_id: "https://poa.st/notes/#{System.unique_integer([:positive])}",
        activitypub_url: "https://poa.st/@waifupoaster/#{System.unique_integer([:positive])}",
        remote_actor_id: remote_actor.id,
        reply_to_id: parent_post.id
      })
      |> Repo.insert()

    reply
  end
end
