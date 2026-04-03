defmodule ElektrineWeb.NotificationsLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Notifications}

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp notification_fixture(user, attrs) do
    {:ok, notification} =
      Notifications.create_notification(
        Map.merge(
          %{
            type: "system",
            title: "Notification #{System.unique_integer([:positive])}",
            body: "Queue item",
            user_id: user.id,
            priority: "normal"
          },
          attrs
        )
      )

    notification
  end

  test "source filter narrows the queue to one lane", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    sender = AccountsFixtures.user_fixture(%{username: "notifsender"})

    notification_fixture(viewer, %{
      type: "new_message",
      title: "New message in Release Room",
      body: "Chat lane body",
      actor_id: sender.id,
      source_type: "message",
      source_id: 42,
      url: "/chat/42"
    })

    notification_fixture(viewer, %{
      type: "email_received",
      title: "Build report arrived",
      body: "Email lane body",
      actor_id: sender.id,
      source_type: "email",
      source_id: 10,
      url: "/email"
    })

    notification_fixture(viewer, %{
      type: "follow",
      title: "New follow request",
      body: "Requests lane body",
      actor_id: sender.id,
      source_type: "user",
      source_id: sender.id,
      url: "/friends?tab=requests"
    })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/notifications?source=chat")

    rendered = render(view)

    assert rendered =~ "Chat lane body"
    refute rendered =~ "Email lane body"
    refute rendered =~ "Requests lane body"
  end

  test "changing state and source filters keeps the queue focus in the URL", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    notification_fixture(viewer, %{title: "System notice", body: "Queue body"})

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/notifications?source=chat")

    view
    |> element(~s(button[phx-click="set_filter"][phx-value-type="unread"]))
    |> render_click()

    assert_patch(view, ~p"/notifications?filter=unread&source=chat")

    view
    |> element(~s(button[phx-click="set_source_filter"][phx-value-source="system"]))
    |> render_click()

    assert_patch(view, ~p"/notifications?filter=unread&source=system")
  end

  test "mark_visible_as_read clears unread items from the filtered queue", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    notification =
      notification_fixture(viewer, %{
        title: "Review access policy",
        body: "System lane body",
        source_type: "system",
        source_id: 1,
        url: "/overview"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/notifications?filter=unread&source=system")

    assert render(view) =~ "Review access policy"
    assert Notifications.get_unread_count(viewer.id) == 1

    render_hook(view, "mark_visible_as_read", %{
      "notification_ids" => [Integer.to_string(notification.id), "not-an-id"]
    })

    assert Notifications.get_unread_count(viewer.id) == 0

    rendered = render(view)
    refute rendered =~ "Review access policy"
    assert rendered =~ "No unread system notifications."
  end

  test "unread filter disables auto-marking visible notifications", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    notification_fixture(viewer, %{title: "Stay visible", body: "Unread body"})

    {:ok, view, html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/notifications?filter=unread&source=all")

    assert html =~ ~s(data-auto-mark-read="false")
    assert render(view) =~ ~s(data-auto-mark-read="false")
  end

  test "single notifications without a body do not render duplicate detail text", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    notification_fixture(viewer, %{
      type: "follow",
      title: "@liaizon@social.wake.st accepted your follow request",
      body: nil,
      source_type: "activitypub_actor",
      source_id: 123,
      url: "/remote/@liaizon@social.wake.st"
    })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/notifications?source=requests")

    rendered = render(view)

    assert Regex.scan(~r/@liaizon@social\.wake\.st accepted your follow request/, rendered)
           |> length() == 1
  end

  test "legacy fediverse follow acceptance notifications render the actor line once", %{
    conn: conn
  } do
    viewer = AccountsFixtures.user_fixture()

    notification_fixture(viewer, %{
      type: "follow",
      title: "Follow request accepted",
      body: "@liaizon@social.wake.st accepted your follow request",
      source_type: "activitypub_actor",
      source_id: 123,
      url: "/remote/@liaizon@social.wake.st"
    })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/notifications?source=requests")

    rendered = render(view)

    assert Regex.scan(~r/@liaizon@social\.wake\.st accepted your follow request/, rendered)
           |> length() == 1

    refute rendered =~ ">Follow request accepted<"
  end
end
