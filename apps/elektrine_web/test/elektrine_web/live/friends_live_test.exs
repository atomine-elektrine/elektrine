defmodule ElektrineWeb.FriendsLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Friends, PubSubTopics}
  alias ElektrineWeb.Presence

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp friendship_fixture(user, friend) do
    {:ok, request} = Friends.send_friend_request(user.id, friend.id)
    {:ok, _accepted_request} = Friends.accept_friend_request(request.id, friend.id)
  end

  defp track_presence(user, status) do
    {:ok, _} =
      Presence.track(self(), PubSubTopics.users_presence(), to_string(user.id), %{
        user_id: user.id,
        username: user.username,
        status: status,
        online_at: System.system_time(:second),
        last_seen_at: System.system_time(:second),
        connection_id: "test-#{user.id}-#{status}",
        device_type: "desktop"
      })
  end

  defp string_index(haystack, needle) do
    case :binary.match(haystack, needle) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  test "friends roster can filter to active friends", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    active_friend = AccountsFixtures.user_fixture(%{username: "activefriend"})
    offline_friend = AccountsFixtures.user_fixture(%{username: "offlinefriend"})

    friendship_fixture(viewer, active_friend)
    friendship_fixture(viewer, offline_friend)
    track_presence(active_friend, "online")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/friends")

    assert has_element?(view, "#friend-row-#{active_friend.id}")
    assert has_element?(view, "#friend-row-#{offline_friend.id}")

    view
    |> element(~s(button[phx-click="set_friend_status_filter"][phx-value-filter="active"]))
    |> render_click()

    assert render(view) =~ "1 of 2 friends"
    assert has_element?(view, "#friend-row-#{active_friend.id}")
    refute has_element?(view, "#friend-row-#{offline_friend.id}")
  end

  test "friends roster can sort by name", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    zed_friend = AccountsFixtures.user_fixture(%{username: "zedsort"})
    alpha_friend = AccountsFixtures.user_fixture(%{username: "alphasort"})

    friendship_fixture(viewer, zed_friend)
    friendship_fixture(viewer, alpha_friend)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/friends")

    view
    |> form("#friend-sort-form", %{"sort" => "name"})
    |> render_change()

    rendered = render(view)

    assert string_index(rendered, "alphasort") < string_index(rendered, "zedsort")
  end
end
