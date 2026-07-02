defmodule Elektrine.Social.NotificationPolicyTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Notifications
  alias Elektrine.Notifications.Notification
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  test "muted local actors cannot create social notifications" do
    recipient = user_fixture()
    actor = user_fixture()
    post = post_fixture(%{user: recipient})

    assert {:ok, _mute} = Accounts.mute_user(recipient.id, actor.id)

    assert {:ok, :notification_filtered} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               actor_id: actor.id,
               type: "like",
               title: "liked your post",
               source_type: "post",
               source_id: post.id
             })

    refute Repo.exists?(Notification)
  end

  test "blocked remote domains cannot create social notifications" do
    recipient = user_fixture()
    actor = remote_actor_fixture("example.org")
    post = post_fixture(%{user: recipient})

    assert {:ok, _instance} = ActivityPub.block_instance("example.org", "test", nil)

    assert {:ok, :notification_filtered} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               type: "mention",
               title: "mentioned you",
               source_type: "post",
               source_id: post.id,
               metadata: %{remote_actor_id: actor.id}
             })

    refute Repo.exists?(Notification)
  end

  test "muted remote actors cannot create social notifications" do
    recipient = user_fixture()
    actor = remote_actor_fixture("muted.example")
    post = post_fixture(%{user: recipient})

    assert {:ok, _mute} = Accounts.mute_remote_actor(recipient.id, actor.id)

    assert {:ok, :notification_filtered} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               type: "mention",
               title: "mentioned you",
               source_type: "post",
               source_id: post.id,
               metadata: %{remote_actor_id: actor.id}
             })

    refute Repo.exists?(Notification)
  end

  test "local strangers cannot create notifications when recipient blocks strangers" do
    recipient = user_fixture(%{block_notifications_from_strangers: true})
    actor = user_fixture()
    post = post_fixture(%{user: recipient})

    assert {:ok, :notification_filtered} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               actor_id: actor.id,
               type: "mention",
               title: "mentioned you",
               source_type: "post",
               source_id: post.id
             })

    refute Repo.exists?(Notification)
  end

  test "followed local actors can create notifications when recipient blocks strangers" do
    recipient = user_fixture(%{block_notifications_from_strangers: true})
    actor = user_fixture()
    post = post_fixture(%{user: recipient})

    assert {:ok, _follow} = Profiles.follow_user(recipient.id, actor.id)

    assert {:ok, %Notification{}} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               actor_id: actor.id,
               type: "mention",
               title: "mentioned you",
               source_type: "post",
               source_id: post.id
             })
  end

  test "remote strangers cannot create notifications when recipient blocks strangers" do
    recipient = user_fixture(%{block_notifications_from_strangers: true})
    actor = remote_actor_fixture("stranger.example")
    post = post_fixture(%{user: recipient})

    assert {:ok, :notification_filtered} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               type: "mention",
               title: "mentioned you",
               source_type: "post",
               source_id: post.id,
               metadata: %{remote_actor_id: actor.id}
             })

    refute Repo.exists?(Notification)
  end

  test "followed remote actors can create notifications when recipient blocks strangers" do
    recipient = user_fixture(%{block_notifications_from_strangers: true})
    actor = remote_actor_fixture("followed.example")
    post = post_fixture(%{user: recipient})

    %Follow{}
    |> Follow.changeset(%{follower_id: recipient.id, remote_actor_id: actor.id, pending: false})
    |> Repo.insert!()

    assert {:ok, %Notification{}} =
             Notifications.create_notification(%{
               user_id: recipient.id,
               type: "mention",
               title: "mentioned you",
               source_type: "post",
               source_id: post.id,
               metadata: %{remote_actor_id: actor.id}
             })
  end

  test "muted local actors are filtered from stored notification lists" do
    recipient = user_fixture()
    actor = user_fixture()
    post = post_fixture(%{user: recipient})

    stored_notification!(%{
      user_id: recipient.id,
      actor_id: actor.id,
      type: "like",
      title: "liked your post",
      source_type: "post",
      source_id: post.id
    })

    assert [_notification] = Notifications.list_notifications(recipient.id)
    assert Notifications.get_visible_unread_count(recipient.id) == 1

    assert {:ok, _mute} = Accounts.mute_user(recipient.id, actor.id)

    assert Notifications.get_unread_count(recipient.id) == 1
    assert Notifications.get_visible_unread_count(recipient.id) == 0
    assert [] = Notifications.list_notifications(recipient.id)
  end

  test "bulk notifications apply policy per recipient" do
    muted_recipient = user_fixture()
    allowed_recipient = user_fixture()
    actor = user_fixture()
    post = post_fixture(%{user: actor})

    assert {:ok, _mute} = Accounts.mute_user(muted_recipient.id, actor.id)

    assert {:ok, 1} =
             Notifications.create_bulk_notifications(
               [muted_recipient.id, allowed_recipient.id],
               %{
                 actor_id: actor.id,
                 type: "like",
                 title: "liked a post",
                 source_type: "post",
                 source_id: post.id
               }
             )

    refute Repo.get_by(Notification, user_id: muted_recipient.id)

    assert %Notification{} =
             Repo.get_by(Notification,
               user_id: allowed_recipient.id,
               actor_id: actor.id,
               source_type: "post",
               source_id: post.id
             )
  end

  test "bulk notifications ignore duplicate recipients" do
    recipient = user_fixture()
    actor = user_fixture()
    post = post_fixture(%{user: actor})

    assert {:ok, 1} =
             Notifications.create_bulk_notifications(
               [recipient.id, recipient.id],
               %{
                 actor_id: actor.id,
                 type: "like",
                 title: "liked a post",
                 source_type: "post",
                 source_id: post.id
               }
             )

    assert Repo.aggregate(Notification, :count, :id) == 1
  end

  test "blocked remote domains are filtered from stored notification lists" do
    recipient = user_fixture()
    actor = remote_actor_fixture("stored.example")
    post = post_fixture(%{user: recipient})

    stored_notification!(%{
      user_id: recipient.id,
      type: "mention",
      title: "mentioned you",
      source_type: "post",
      source_id: post.id,
      metadata: %{remote_actor_id: actor.id}
    })

    assert [_notification] = Notifications.list_notifications(recipient.id)
    assert Notifications.get_visible_unread_count(recipient.id) == 1

    assert {:ok, _instance} = ActivityPub.block_instance("stored.example", "test", nil)

    assert Notifications.get_unread_count(recipient.id) == 1
    assert Notifications.get_visible_unread_count(recipient.id) == 0
    assert [] = Notifications.list_notifications(recipient.id)
  end

  defp stored_notification!(attrs) do
    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert!()
  end

  defp remote_actor_fixture(domain) do
    {:ok, actor} =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{domain}/users/bob",
        username: "bob",
        domain: domain,
        inbox_url: "https://#{domain}/users/bob/inbox",
        public_key: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
        actor_type: "Person",
        last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end
end
