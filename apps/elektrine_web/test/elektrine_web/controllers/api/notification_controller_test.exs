defmodule ElektrineWeb.API.NotificationControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Notifications
  alias Elektrine.Notifications.Notification
  alias Elektrine.Repo
  alias ElektrineWeb.API.NotificationController

  describe "index/2" do
    test "filters stored notifications by current mute policy and visible unread count", %{
      conn: conn
    } do
      recipient = user_fixture()
      muted_actor = user_fixture()
      visible_actor = user_fixture()
      post = post_fixture(%{user: recipient})

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: muted_actor.id,
        type: "like",
        title: "muted actor liked your post",
        source_type: "post",
        source_id: post.id
      })

      visible =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: visible_actor.id,
          type: "reply",
          title: "visible actor replied",
          source_type: "post",
          source_id: post.id
        })

      assert {:ok, _mute} = Accounts.mute_user(recipient.id, muted_actor.id)

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.index(%{})

      assert %{"notifications" => [notification], "unread_count" => 1} =
               json_response(conn, 200)

      assert notification["id"] == visible.id
      assert notification["actor"]["id"] == visible_actor.id
    end
  end

  describe "v1_index/2" do
    test "returns the compatible notification array shape", %{conn: conn} do
      recipient = user_fixture()
      actor = user_fixture()

      notification =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: actor.id,
          type: "mention",
          title: "mentioned you"
        })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v1_index(%{})

      assert [
               %{
                 "id" => id,
                 "type" => "mention",
                 "actor" => %{"id" => actor_id},
                 "created_at" => created_at,
                 "inserted_at" => inserted_at,
                 "pleroma" => %{"is_seen" => false, "is_muted" => false}
               }
             ] =
               json_response(conn, 200)

      assert id == notification.id
      assert actor_id == actor.id
      assert created_at == inserted_at
    end

    test "includes standard account and status entities for social notifications", %{conn: conn} do
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

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v1_index(%{})

      assert [%{"account" => account, "status" => status, "actor" => legacy_actor}] =
               json_response(conn, 200)

      assert account["id"] == to_string(actor.id)
      assert account["acct"] == (actor.handle || actor.username)
      assert account["username"] == actor.username
      assert Map.has_key?(account, "followers_count")
      assert legacy_actor["id"] == actor.id

      assert status["id"] == to_string(post.id)
      assert status["account"]["id"] == to_string(recipient.id)
      assert status["content"] == post.content
    end

    test "omits status entities for missing or invisible sources", %{conn: conn} do
      recipient = user_fixture()
      actor = user_fixture()

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: actor.id,
        type: "like",
        title: "liked a deleted post",
        source_type: "post",
        source_id: 999_999_999
      })

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: actor.id,
        type: "follow",
        title: "followed you",
        source_type: "user",
        source_id: actor.id
      })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v1_index(%{})

      assert [first, second] = json_response(conn, 200)
      assert first["status"] == nil
      assert second["status"] == nil
      assert first["account"]["id"] == to_string(actor.id)
    end

    test "returns remote actors from notification metadata", %{conn: conn} do
      recipient = user_fixture()
      remote_actor = remote_actor_fixture("v1remote", "remote.example")

      notification =
        stored_notification!(%{
          user_id: recipient.id,
          type: "follow",
          title: "remote follow",
          source_type: "activitypub_actor",
          source_id: remote_actor.id,
          metadata: %{"remote_actor_id" => remote_actor.id}
        })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v1_index(%{})

      assert [
               %{
                 "id" => id,
                 "actor" => %{"id" => remote_id, "remote" => true},
                 "account" => account
               }
             ] =
               json_response(conn, 200)

      assert id == notification.id
      assert remote_id == "remote:#{remote_actor.id}"
      assert account["id"] == remote_id
      assert account["acct"] == "v1remote@remote.example"
    end
  end

  describe "show/2" do
    test "returns a visible notification", %{conn: conn} do
      recipient = user_fixture()

      notification =
        stored_notification!(%{
          user_id: recipient.id,
          type: "system",
          title: "system notice"
        })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.show(%{"id" => to_string(notification.id)})

      assert %{
               "id" => id,
               "title" => "system notice",
               "created_at" => created_at,
               "pleroma" => %{"is_seen" => false}
             } = json_response(conn, 200)

      assert id == notification.id
      assert created_at
    end

    test "hides missing, dismissed, and muted notifications", %{conn: conn} do
      recipient = user_fixture()
      muted_actor = user_fixture()

      dismissed =
        stored_notification!(%{
          user_id: recipient.id,
          type: "system",
          title: "dismissed",
          dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      muted =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: muted_actor.id,
          type: "like",
          title: "muted"
        })

      assert {:ok, _mute} = Accounts.mute_user(recipient.id, muted_actor.id)

      dismissed_conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.show(%{"id" => to_string(dismissed.id)})

      muted_conn =
        build_conn()
        |> assign(:current_user, recipient)
        |> NotificationController.show(%{"id" => to_string(muted.id)})

      assert %{"error" => "notification not found"} = json_response(dismissed_conn, 404)
      assert %{"error" => "notification not found"} = json_response(muted_conn, 404)
    end
  end

  describe "unread_count/2" do
    test "returns visible unread notification count", %{conn: conn} do
      recipient = user_fixture()
      muted_actor = user_fixture()

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: muted_actor.id,
        type: "like",
        title: "hidden unread"
      })

      stored_notification!(%{
        user_id: recipient.id,
        type: "system",
        title: "visible unread"
      })

      assert {:ok, _mute} = Accounts.mute_user(recipient.id, muted_actor.id)

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.unread_count(%{})

      assert %{"count" => 1} = json_response(conn, 200)
    end

    test "counts unread notification groups instead of raw rows", %{conn: conn} do
      recipient = user_fixture()
      first_actor = user_fixture()
      second_actor = user_fixture()
      post = post_fixture(%{user: recipient})
      group_key = "social:like:post:#{post.id}"

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: first_actor.id,
        group_key: group_key,
        type: "like",
        title: "first like",
        source_type: "post",
        source_id: post.id
      })

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: second_actor.id,
        group_key: group_key,
        type: "like",
        title: "second like",
        source_type: "post",
        source_id: post.id
      })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.unread_count(%{})

      assert %{"count" => 1} = json_response(conn, 200)
    end
  end

  describe "v2 grouped notifications" do
    test "source filters include compatible social and admin notification types", %{conn: conn} do
      recipient = user_fixture()
      post = post_fixture(%{visibility: "public"})

      status =
        stored_notification!(%{
          user_id: recipient.id,
          type: "status",
          title: "status alert",
          source_type: "message",
          source_id: post.id
        })

      admin =
        stored_notification!(%{
          user_id: recipient.id,
          type: "admin.report",
          title: "report alert"
        })

      social_conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v2_index(%{"source_filter" => "social"})

      assert %{"notification_groups" => [social_group]} = json_response(social_conn, 200)
      assert social_group["type"] == "status"
      assert social_group["most_recent_notification_id"] == to_string(status.id)

      system_conn =
        build_conn()
        |> assign(:current_user, recipient)
        |> NotificationController.v2_index(%{"source_filter" => "system"})

      assert %{"notification_groups" => [system_group]} = json_response(system_conn, 200)
      assert system_group["type"] == "admin.report"
      assert system_group["most_recent_notification_id"] == to_string(admin.id)
    end

    test "groups notifications and exposes sample accounts", %{conn: conn} do
      recipient = user_fixture()
      first_actor = user_fixture()
      second_actor = user_fixture()
      post = post_fixture(%{user: recipient})
      group_key = "social:like:post:#{post.id}"

      first =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: first_actor.id,
          group_key: group_key,
          type: "like",
          title: "first like",
          source_type: "post",
          source_id: post.id
        })

      second =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: second_actor.id,
          group_key: group_key,
          type: "like",
          title: "second like",
          source_type: "post",
          source_id: post.id
        })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v2_index(%{})

      assert %{
               "accounts" => accounts,
               "statuses" => [status],
               "notification_groups" => [group]
             } = json_response(conn, 200)

      assert group["group_key"] == group_key
      assert group["notifications_count"] == 2
      assert group["type"] == "like"
      assert group["status_id"] == to_string(post.id)
      assert status["id"] == to_string(post.id)
      assert status["account"]["id"] == to_string(recipient.id)
      assert group["most_recent_notification_id"] in [to_string(first.id), to_string(second.id)]

      assert Enum.sort(group["sample_account_ids"]) ==
               Enum.sort([to_string(first_actor.id), to_string(second_actor.id)])

      assert Enum.sort(Enum.map(accounts, & &1["id"])) ==
               Enum.sort([first_actor.id, second_actor.id])
    end

    test "groups subscribed-account status notifications by source post", %{conn: conn} do
      recipient = user_fixture()
      first_actor = user_fixture()
      second_actor = user_fixture()
      post = post_fixture(%{user: first_actor})
      group_key = "social:status:message:#{post.id}"

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: first_actor.id,
        group_key: group_key,
        type: "status",
        title: "first status",
        source_type: "message",
        source_id: post.id
      })

      stored_notification!(%{
        user_id: recipient.id,
        actor_id: second_actor.id,
        group_key: group_key,
        type: "status",
        title: "second status",
        source_type: "message",
        source_id: post.id
      })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v2_index(%{})

      assert %{"notification_groups" => [group]} = json_response(conn, 200)
      assert group["group_key"] == group_key
      assert group["notifications_count"] == 2
      assert group["type"] == "status"
      assert group["status_id"] == to_string(post.id)
    end

    test "groups remote actor notifications with account samples", %{conn: conn} do
      recipient = user_fixture()
      remote_actor = remote_actor_fixture("notifremote", "remote.example")
      post = post_fixture(%{user: recipient})
      group_key = "social:like:message:#{post.id}"

      notification =
        stored_notification!(%{
          user_id: recipient.id,
          group_key: group_key,
          type: "like",
          title: "remote like",
          source_type: "message",
          source_id: post.id,
          metadata: %{remote_actor_id: remote_actor.id}
        })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v2_index(%{})

      assert %{
               "accounts" => [account],
               "notification_groups" => [group]
             } = json_response(conn, 200)

      remote_id = "remote:#{remote_actor.id}"

      assert group["sample_account_ids"] == [remote_id]
      assert group["most_recent_notification_id"] == to_string(notification.id)
      assert account["id"] == remote_id
      assert account["acct"] == "notifremote@remote.example"

      accounts_conn =
        build_conn()
        |> assign(:current_user, recipient)
        |> NotificationController.group_accounts(%{"group_key" => group_key})

      assert [%{"id" => ^remote_id}] = json_response(accounts_conn, 200)
    end

    test "exposes remote actor samples for single notification groups", %{conn: conn} do
      recipient = user_fixture()
      remote_actor = remote_actor_fixture("singlefollow", "remote.example")

      stored_notification!(%{
        user_id: recipient.id,
        type: "follow",
        title: "remote follow",
        source_type: "activitypub_actor",
        source_id: remote_actor.id,
        metadata: %{remote_actor_id: remote_actor.id}
      })

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.v2_index(%{})

      remote_id = "remote:#{remote_actor.id}"

      assert %{
               "accounts" => [%{"id" => ^remote_id}],
               "notification_groups" => [%{"sample_account_ids" => [^remote_id]}]
             } = json_response(conn, 200)
    end

    test "shows group, lists group accounts, and dismisses group", %{conn: conn} do
      recipient = user_fixture()
      first_actor = user_fixture()
      second_actor = user_fixture()
      post = post_fixture(%{user: recipient})
      group_key = "social:boost:post:#{post.id}"

      first =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: first_actor.id,
          group_key: group_key,
          type: "boost",
          title: "first boost",
          source_type: "post",
          source_id: post.id
        })

      second =
        stored_notification!(%{
          user_id: recipient.id,
          actor_id: second_actor.id,
          group_key: group_key,
          type: "boost",
          title: "second boost",
          source_type: "post",
          source_id: post.id
        })

      show_conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.show_group(%{"group_key" => group_key})

      assert %{"notification_groups" => [group], "statuses" => [status]} =
               json_response(show_conn, 200)

      assert group["group_key"] == group_key
      assert status["id"] == to_string(post.id)
      refute Map.has_key?(group, "page_min_id")

      accounts_conn =
        build_conn()
        |> assign(:current_user, recipient)
        |> NotificationController.group_accounts(%{"group_key" => group_key})

      assert accounts_conn
             |> json_response(200)
             |> Enum.map(& &1["id"])
             |> Enum.sort() == Enum.sort([first_actor.id, second_actor.id])

      dismiss_conn =
        build_conn()
        |> assign(:current_user, recipient)
        |> NotificationController.dismiss_group(%{"group_key" => group_key})

      assert %{} = json_response(dismiss_conn, 200)
      assert Repo.get!(Notification, first.id).dismissed_at
      assert Repo.get!(Notification, second.id).dismissed_at
    end
  end

  describe "clear/2" do
    test "dismisses all notifications for the current user", %{conn: conn} do
      recipient = user_fixture()

      first = stored_notification!(%{user_id: recipient.id, type: "system", title: "one"})
      second = stored_notification!(%{user_id: recipient.id, type: "system", title: "two"})

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.clear(%{})

      assert %{} = json_response(conn, 200)
      assert Repo.get!(Notification, first.id).dismissed_at
      assert Repo.get!(Notification, second.id).dismissed_at
      assert Notifications.get_visible_unread_count(recipient.id) == 0
    end
  end

  describe "mark_read_via_body/2" do
    test "marks one notification as read by body id", %{conn: conn} do
      recipient = user_fixture()
      notification = stored_notification!(%{user_id: recipient.id, type: "system", title: "one"})

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.mark_read_via_body(%{"id" => to_string(notification.id)})

      assert "ok" = json_response(conn, 200)
      assert Repo.get!(Notification, notification.id).read_at
    end

    test "marks notifications up to max_id as read", %{conn: conn} do
      recipient = user_fixture()
      older = stored_notification!(%{user_id: recipient.id, type: "system", title: "older"})
      newer = stored_notification!(%{user_id: recipient.id, type: "system", title: "newer"})

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.mark_read_via_body(%{"max_id" => to_string(older.id)})

      assert "ok" = json_response(conn, 200)
      assert Repo.get!(Notification, older.id).read_at
      refute Repo.get!(Notification, newer.id).read_at
    end
  end

  describe "destroy_multiple/2" do
    test "dismisses only selected notifications owned by the current user", %{conn: conn} do
      recipient = user_fixture()
      other_user = user_fixture()

      first = stored_notification!(%{user_id: recipient.id, type: "system", title: "one"})
      second = stored_notification!(%{user_id: recipient.id, type: "system", title: "two"})
      keep = stored_notification!(%{user_id: recipient.id, type: "system", title: "keep"})
      other = stored_notification!(%{user_id: other_user.id, type: "system", title: "other"})

      conn =
        conn
        |> assign(:current_user, recipient)
        |> NotificationController.destroy_multiple(%{
          "ids" => "#{first.id},#{second.id},#{other.id}"
        })

      assert %{"dismissed" => 2} = json_response(conn, 200)
      assert Repo.get!(Notification, first.id).dismissed_at
      assert Repo.get!(Notification, second.id).dismissed_at
      refute Repo.get!(Notification, keep.id).dismissed_at
      refute Repo.get!(Notification, other.id).dismissed_at
    end
  end

  defp stored_notification!(attrs) do
    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert!()
  end

  defp remote_actor_fixture(username, domain) do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: username,
      summary: "",
      inbox_url: "https://#{domain}/inbox",
      outbox_url: "https://#{domain}/users/#{username}/outbox",
      public_key: "test-public-key-#{unique}",
      actor_type: "Person",
      manually_approves_followers: false,
      metadata: %{}
    })
    |> Repo.insert!()
  end
end
