defmodule ElektrineWeb.OverviewLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.{AccountsFixtures, Friends, Profiles, Social}

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, reason} = live(conn, ~p"/overview")

    assert match?({:redirect, %{to: "/login"}}, reason) or
             match?({:live_redirect, %{to: "/login"}}, reason)
  end

  test "invalid filter param falls back to default overview content", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview?filter=not-real")

    assert html =~ "Attention Queue"

    assert has_element?(
             view,
             ~s(button[phx-click="set_filter"][phx-value-filter="all"].btn-secondary)
           )

    assert html =~ "0 posts"
  end

  test "shell includes a global composer menu", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    assert html =~ ~s(data-test="global-composer")
    assert html =~ "Quick Create"
    assert html =~ "/timeline?composer=note"
    assert html =~ "/calendar?composer=task"
  end

  test "recent activity list is rendered as a scroll container", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    assert has_element?(view, ~s([data-role="recent-activity-list"].overflow-y-auto.pr-1))
  end

  test "attention queue is rendered as a scroll container", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    assert has_element?(view, ~s([data-role="attention-queue-list"].overflow-y-auto.pr-1))
  end

  test "attention queue can be filtered to requests", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    requester = AccountsFixtures.user_fixture()

    {:ok, _request} = Friends.send_friend_request(requester.id, viewer.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/overview")

    assert render(view) =~ "Respond to friend requests"

    view
    |> element(~s(button[phx-click="set_attention_filter"][phx-value-filter="requests"]))
    |> render_click()

    assert_patch(view, ~p"/overview?filter=all&attention=requests")
    assert render(view) =~ "Respond to friend requests"
  end

  test "invalid like_post id does not crash and shows an error", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    render_hook(view, "like_post", %{"message_id" => "abc"})
    assert render(view) =~ "Invalid post id"
  end

  test "unfollowing from overview does not crash when the follow exists", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, _post} =
      Social.create_timeline_post(author.id, "Overview follow regression target",
        visibility: "public"
      )

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, author.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/overview")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "Overview follow regression target" and
             has_element?(
               view,
               ~s(button[phx-click="toggle_follow"][phx-value-user_id="#{author.id}"]),
               "Unfollow"
             ) do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Overview follow regression target"
    assert Profiles.following?(viewer.id, author.id)

    view
    |> element(~s(button[phx-click="toggle_follow"][phx-value-user_id="#{author.id}"]))
    |> render_click()

    refute Profiles.following?(viewer.id, author.id)

    assert has_element?(
             view,
             ~s(button[phx-click="toggle_follow"][phx-value-user_id="#{author.id}"]),
             "Follow"
           )
  end
end
