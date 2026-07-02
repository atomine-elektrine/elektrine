defmodule Elektrine.PushTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.{AccountsFixtures, Push, Repo}
  alias Elektrine.Push.{DeviceToken, WebSubscription}
  alias Elektrine.Secrets.EncryptedString

  defmodule ConnectedPresence do
    def get_by_key("mobile:users", "123"), do: [%{metas: [%{user_id: 123}]}]
    def get_by_key(_topic, _key), do: []
  end

  defmodule UnavailablePresence do
    def get_by_key(_topic, _key) do
      raise ArgumentError, "the table identifier does not refer to an existing ETS table"
    end
  end

  defmodule WebPushClient do
    def deliver(subscription, payload, test_pid) do
      send(test_pid, {:web_push_delivered, subscription.id, payload})
      {:ok, :sent}
    end
  end

  defmodule FailingWebPushClient do
    def deliver(_subscription, _payload, _opts), do: {:error, :gone}
  end

  test "returns false when web runtime component is disabled" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: false,
             presence_running?: true,
             presence_module: ConnectedPresence
           )
  end

  test "returns false when the presence process is not running" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: false,
             presence_module: ConnectedPresence
           )
  end

  test "returns false when the presence tracker ETS table is unavailable" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: true,
             presence_module: UnavailablePresence
           )
  end

  test "returns true when presence lookup finds an active connection" do
    assert Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: true,
             presence_module: ConnectedPresence
           )
  end

  test "register_device stores encrypted token and lookup hash" do
    user = AccountsFixtures.user_fixture()
    token = "ExponentPushToken[abc123]"

    assert {:ok, device} =
             Push.register_device(user.id, %{
               token: token,
               platform: "android",
               device_name: "Pixel"
             })

    assert device.token == token
    assert device.token_hash == Push.device_token_hash(token)

    [[stored_token, stored_token_hash]] =
      Repo.query!("SELECT token, token_hash FROM device_tokens WHERE id = $1", [device.id]).rows

    assert EncryptedString.encrypted?(stored_token)
    refute stored_token == token
    assert stored_token_hash == Push.device_token_hash(token)
    assert Push.get_device_by_token(token).id == device.id
  end

  test "register_device updates existing devices by token hash" do
    user = AccountsFixtures.user_fixture()
    token = "ExponentPushToken[update-me]"

    assert {:ok, first} = Push.register_device(user.id, %{token: token, platform: "android"})

    assert {:ok, second} =
             Push.register_device(user.id, %{
               token: token,
               platform: "android",
               device_name: "Updated"
             })

    assert second.id == first.id
    assert second.device_name == "Updated"
    assert Repo.aggregate(DeviceToken, :count) == 1
  end

  test "unregister_device deletes by token hash" do
    user = AccountsFixtures.user_fixture()
    token = "ExponentPushToken[delete-me]"

    assert {:ok, device} = Push.register_device(user.id, %{token: token, platform: "android"})
    assert {:ok, _deleted} = Push.unregister_device(token)
    refute Repo.get(DeviceToken, device.id)
  end

  test "upsert_web_subscription stores encrypted endpoint and keys with lookup hash" do
    user = AccountsFixtures.user_fixture()
    endpoint = "https://push.example/subscriptions/abc123"

    assert {:ok, subscription} =
             Push.upsert_web_subscription(user.id, %{
               "subscription" => %{
                 "endpoint" => endpoint,
                 "keys" => %{"p256dh" => "public-key", "auth" => "auth-secret"}
               },
               "data" => %{
                 "alerts" => %{"mention" => true, "status" => false},
                 "policy" => "followed"
               }
             })

    assert subscription.endpoint == endpoint
    assert subscription.p256dh == "public-key"
    assert subscription.auth == "auth-secret"
    assert subscription.endpoint_hash == Push.web_push_endpoint_hash(endpoint)
    assert subscription.policy == "followed"
    assert subscription.alerts["mention"] == true

    [[stored_endpoint, stored_p256dh, stored_auth, stored_hash]] =
      Repo.query!(
        "SELECT endpoint, p256dh, auth, endpoint_hash FROM web_push_subscriptions WHERE id = $1",
        [subscription.id]
      ).rows

    assert EncryptedString.encrypted?(stored_endpoint)
    assert EncryptedString.encrypted?(stored_p256dh)
    assert EncryptedString.encrypted?(stored_auth)
    refute stored_endpoint == endpoint
    assert stored_hash == Push.web_push_endpoint_hash(endpoint)
  end

  test "upsert_web_subscription updates existing subscriptions by endpoint hash" do
    user = AccountsFixtures.user_fixture()
    endpoint = "https://push.example/subscriptions/update"

    assert {:ok, first} =
             Push.upsert_web_subscription(user.id, web_subscription_attrs(endpoint, "all"))

    assert {:ok, second} =
             Push.upsert_web_subscription(user.id, web_subscription_attrs(endpoint, "none"))

    assert second.id == first.id
    assert second.policy == "none"
    assert Repo.aggregate(WebSubscription, :count) == 1
  end

  test "update and delete current web subscription" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/delete", "all")
             )

    assert {:ok, updated} =
             Push.update_web_subscription(user.id, %{
               "data" => %{"alerts" => %{"follow" => false}, "policy" => "none"}
             })

    assert updated.id == subscription.id
    assert updated.alerts["follow"] == false
    assert updated.policy == "none"

    assert {:ok, _deleted} = Push.delete_web_subscription(user.id)
    refute Push.get_web_subscription(user.id)
  end

  test "notify_web_user delivers only allowed alert and policy subscriptions" do
    user = AccountsFixtures.user_fixture()
    actor = AccountsFixtures.user_fixture()
    follower = AccountsFixtures.user_fixture()
    unrelated = AccountsFixtures.user_fixture()

    assert {:ok, _follow} = Elektrine.Profiles.follow_user(user.id, actor.id)
    assert {:ok, _follow} = Elektrine.Profiles.follow_user(follower.id, user.id)

    Application.put_env(:elektrine, :web_push_client, {WebPushClient, self()})
    on_exit(fn -> Application.delete_env(:elektrine, :web_push_client) end)

    assert {:ok, followed_subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/followed", "followed")
             )

    assert {:ok, follower_subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/follower", "follower")
             )

    assert {:ok, _none_subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/none", "none")
             )

    assert {:ok, muted_subscription} =
             Push.upsert_web_subscription(
               user.id,
               %{
                 "subscription" => %{
                   "endpoint" => "https://push.example/subscriptions/muted",
                   "keys" => %{"p256dh" => "public-key", "auth" => "auth-secret"}
                 },
                 "data" => %{"alerts" => %{"mention" => false}, "policy" => "all"}
               }
             )

    muted_subscription_id = muted_subscription.id

    assert {:ok, 1} =
             Push.notify_web_user(user.id, %{
               type: "mention",
               actor_id: actor.id,
               title: "Mention",
               body: "Hello"
             })

    assert_receive {:web_push_delivered, delivered_id, %{title: "Mention"}}
    assert delivered_id == followed_subscription.id

    assert {:ok, 1} =
             Push.notify_web_user(user.id, %{
               type: "mention",
               actor_id: follower.id,
               title: "Follower",
               body: "Hello"
             })

    assert_receive {:web_push_delivered, delivered_id, %{title: "Follower"}}
    assert delivered_id == follower_subscription.id

    assert {:ok, 0} =
             Push.notify_web_user(user.id, %{
               type: "mention",
               actor_id: unrelated.id,
               title: "No delivery",
               body: "Hello"
             })

    refute_receive {:web_push_delivered, _id, %{title: "No delivery"}}, 50
    refute_receive {:web_push_delivered, ^muted_subscription_id, _payload}, 50
  end

  test "notify_web_user maps internal like and boost notifications to compatible alert names" do
    user = AccountsFixtures.user_fixture()
    actor = AccountsFixtures.user_fixture()

    Application.put_env(:elektrine, :web_push_client, {WebPushClient, self()})
    on_exit(fn -> Application.delete_env(:elektrine, :web_push_client) end)

    assert {:ok, _subscription} =
             Push.upsert_web_subscription(
               user.id,
               %{
                 "subscription" => %{
                   "endpoint" => "https://push.example/subscriptions/alert-aliases",
                   "keys" => %{"p256dh" => "public-key", "auth" => "auth-secret"}
                 },
                 "data" => %{
                   "alerts" => %{"favourite" => false, "reblog" => false},
                   "policy" => "all"
                 }
               }
             )

    assert {:ok, 0} =
             Push.notify_web_user(user.id, %{
               type: "like",
               actor_id: actor.id,
               title: "Like",
               body: "Liked"
             })

    assert {:ok, 0} =
             Push.notify_web_user(user.id, %{
               type: "boost",
               actor_id: actor.id,
               title: "Boost",
               body: "Boosted"
             })

    refute_receive {:web_push_delivered, _id, _payload}, 50
  end

  test "notify_web_user lets explicit internal alert keys override compatible aliases" do
    user = AccountsFixtures.user_fixture()
    actor = AccountsFixtures.user_fixture()

    Application.put_env(:elektrine, :web_push_client, {WebPushClient, self()})
    on_exit(fn -> Application.delete_env(:elektrine, :web_push_client) end)

    assert {:ok, subscription} =
             Push.upsert_web_subscription(
               user.id,
               %{
                 "subscription" => %{
                   "endpoint" => "https://push.example/subscriptions/internal-alert-key",
                   "keys" => %{"p256dh" => "public-key", "auth" => "auth-secret"}
                 },
                 "data" => %{
                   "alerts" => %{"favourite" => false, "like" => true},
                   "policy" => "all"
                 }
               }
             )

    assert {:ok, 1} =
             Push.notify_web_user(user.id, %{
               type: "like",
               actor_id: actor.id,
               title: "Like",
               body: "Liked"
             })

    assert_receive {:web_push_delivered, delivered_id, %{title: "Like"}}
    assert delivered_id == subscription.id
  end

  test "send_to_web_subscription records failures and disables after repeated failures" do
    user = AccountsFixtures.user_fixture()

    Application.put_env(:elektrine, :web_push_client, FailingWebPushClient)
    on_exit(fn -> Application.delete_env(:elektrine, :web_push_client) end)

    assert {:ok, subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/fail", "all")
             )

    failed =
      Enum.reduce(1..5, subscription, fn _attempt, subscription ->
        assert {:error, :gone} = Push.send_to_web_subscription(subscription, %{title: "Fail"})
        Repo.get!(WebSubscription, subscription.id)
      end)

    assert failed.failed_count == 5
    assert failed.enabled == false
    assert failed.last_error == ":gone"
  end

  test "created notifications dispatch browser web push payloads" do
    user = AccountsFixtures.user_fixture()

    Application.put_env(:elektrine, :web_push_client, {WebPushClient, self()})
    on_exit(fn -> Application.delete_env(:elektrine, :web_push_client) end)

    assert {:ok, subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/notification", "all")
             )

    assert {:ok, notification} =
             Elektrine.Notifications.create_notification(%{
               type: "mention",
               title: "New mention",
               body: "Someone mentioned you",
               url: "/timeline/1",
               user_id: user.id
             })

    assert_receive {:web_push_delivered, delivered_id, payload}
    assert delivered_id == subscription.id
    assert payload.title == "New mention"
    assert payload.body == "Someone mentioned you"
    assert payload.data.notification_id == notification.id
    assert payload.data.url == "/timeline/1"
  end

  test "created notifications redact browser web push contents when enabled" do
    user = AccountsFixtures.user_fixture(%{hide_notification_contents: true})

    Application.put_env(:elektrine, :web_push_client, {WebPushClient, self()})
    on_exit(fn -> Application.delete_env(:elektrine, :web_push_client) end)

    assert {:ok, subscription} =
             Push.upsert_web_subscription(
               user.id,
               web_subscription_attrs("https://push.example/subscriptions/redacted", "all")
             )

    assert {:ok, notification} =
             Elektrine.Notifications.create_notification(%{
               type: "mention",
               title: "New mention",
               body: "Someone mentioned you",
               url: "/timeline/1",
               user_id: user.id
             })

    assert_receive {:web_push_delivered, delivered_id, payload}
    assert delivered_id == subscription.id
    assert payload.title == "New notification"
    assert payload.body == "Open Elektrine to view it."
    assert payload.data.notification_id == notification.id
    assert payload.data.url == "/timeline/1"
  end

  defp web_subscription_attrs(endpoint, policy) do
    %{
      "subscription" => %{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => "public-key", "auth" => "auth-secret"}
      },
      "data" => %{"policy" => policy}
    }
  end
end
