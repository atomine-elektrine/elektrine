defmodule Elektrine.Notifications.FederationNotificationsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Notifications.FederationNotifications
  alias Elektrine.Repo

  import Elektrine.AccountsFixtures

  describe "federated follow notifications" do
    test "follow acceptance stores a clean single-line notification with a profile link" do
      user = user_fixture()
      actor = remote_actor_fixture("liaizon")

      assert {:ok, notification} =
               FederationNotifications.notify_follow_accepted(user.id, actor.uri)

      assert notification.title == "@liaizon@social.wake.st accepted your follow request"
      assert notification.body == nil
      assert notification.url == "/remote/@liaizon@social.wake.st"
      assert notification.source_type == "activitypub_actor"
      assert notification.source_id == actor.id
    end

    test "remote follow notifications link to the remote profile" do
      user = user_fixture()
      actor = remote_actor_fixture("nixcraft")

      assert {:ok, notification} =
               FederationNotifications.notify_remote_follow(user.id, actor.id)

      assert notification.title == "@nixcraft@social.wake.st is now following you"
      assert notification.body == nil
      assert notification.url == "/remote/@nixcraft@social.wake.st"
      assert notification.source_type == "activitypub_actor"
      assert notification.source_id == actor.id
    end
  end

  defp remote_actor_fixture(username) do
    {:ok, actor} =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://social.wake.st/users/#{username}-#{System.unique_integer([:positive])}",
        username: username,
        domain: "social.wake.st",
        inbox_url: "https://social.wake.st/inbox",
        public_key: "test-public-key"
      })
      |> Repo.insert()

    actor
  end
end
