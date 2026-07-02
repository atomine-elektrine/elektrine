defmodule Elektrine.Social.AccountSubscriptionNotificationsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Messages

  test "subscribed users receive status notifications for local posts" do
    subscriber = user_fixture()
    author = user_fixture(%{display_name: "Ada"})

    assert {:ok, _subscription} = Accounts.subscribe_to_account(subscriber.id, author)

    assert {:ok, post} =
             Social.create_timeline_post(author.id, "subscription-worthy update",
               visibility: "public"
             )

    assert %Notification{} = notification = Repo.one(Notification)
    assert notification.user_id == subscriber.id
    assert notification.actor_id == author.id
    assert notification.type == "status"
    assert notification.title == "#{author.username} posted"
    assert notification.source_type == "message"
    assert notification.source_id == post.id
  end

  test "subscribed account notifications still honor mute policy" do
    subscriber = user_fixture()
    author = user_fixture()

    assert {:ok, _subscription} = Accounts.subscribe_to_account(subscriber.id, author)
    assert {:ok, _mute} = Accounts.mute_user(subscriber.id, author.id, true)

    assert {:ok, _post} =
             Social.create_timeline_post(author.id, "muted update", visibility: "public")

    refute Repo.exists?(Notification)
  end

  test "subscribed users receive status notifications for remote posts" do
    subscriber = user_fixture()
    actor = remote_actor_fixture("notify.example")

    assert {:ok, _subscription} = Accounts.subscribe_to_account(subscriber.id, actor)

    assert {:ok, post} =
             Messages.create_federated_message(%{
               content: "remote subscription update",
               activitypub_id:
                 "https://notify.example/objects/#{System.unique_integer([:positive])}",
               activitypub_url:
                 "https://notify.example/posts/#{System.unique_integer([:positive])}",
               remote_actor_id: actor.id,
               visibility: "public",
               post_type: "post"
             })

    assert %Notification{} = notification = Repo.one(Notification)
    assert notification.user_id == subscriber.id
    assert notification.actor_id == nil
    assert notification.type == "status"
    assert notification.title == "Remote Alice posted"
    assert notification.metadata == %{"remote_actor_id" => actor.id}
    assert notification.source_id == post.id
  end

  defp remote_actor_fixture(domain) do
    {:ok, actor} =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{domain}/users/alice",
        username: "alice",
        display_name: "Remote Alice",
        domain: domain,
        inbox_url: "https://#{domain}/users/alice/inbox",
        public_key: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
        actor_type: "Person",
        last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end
end
