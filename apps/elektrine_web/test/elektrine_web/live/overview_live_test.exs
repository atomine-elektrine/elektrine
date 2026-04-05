defmodule ElektrineWeb.OverviewLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Elektrine.SocialFixtures, only: [post_fixture: 1]

  alias Elektrine.{AccountsFixtures, Friends, Messaging, Profiles, Repo, Social}
  alias Elektrine.ActivityPub.Actor

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

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

  test "overview renders a taller loading shell before feed hydration", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/overview")
      |> html_response(200)

    assert html =~ ~s(phx-hook="TimelineReply")
    assert html =~ "space-y-4 min-h-[60vh]"
    assert html =~ "data-feed-loading-skeleton"
  end

  test "overview uses the infinite scroll feed container", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/overview")

    assert has_element?(view, ~s(#overview-infinite-scroll[phx-hook="InfiniteScroll"]))
    assert has_element?(view, ~s(#overview-posts-list))
  end

  test "overview feed stays capped to a dashboard-sized batch", %{conn: conn} do
    previous = Application.get_env(:elektrine, :recommendations_enabled, true)
    Application.put_env(:elektrine, :recommendations_enabled, false)
    on_exit(fn -> Application.put_env(:elektrine, :recommendations_enabled, previous) end)

    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    for index <- 1..25 do
      post_fixture(%{
        user: author,
        content: "Overview batch token #{String.pad_leading(Integer.to_string(index), 2, "0")}",
        visibility: "public"
      })
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/overview")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "Overview batch token 25" do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "20 posts"
    assert html =~ "Overview batch token 25"
    refute html =~ "Overview batch token 01"
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

  test "not interested removes a post from the overview feed", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Overview dismissal target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/overview")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "Overview dismissal target" and
             has_element?(
               view,
               ~s(button[phx-click="not_interested"][phx-value-post_id="#{post.id}"])
             ) do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Overview dismissal target"

    view
    |> element(~s(button[phx-click="not_interested"][phx-value-post_id="#{post.id}"]))
    |> render_click()

    refute render(view) =~ "Overview dismissal target"
  end

  test "overview renders community posts with the same lemmy layout as timeline", %{conn: _conn} do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://community.example/users/poster#{unique}",
        username: "poster#{unique}",
        domain: "community.example",
        display_name: "Poster #{unique}",
        inbox_url: "https://community.example/inbox",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    {:ok, post} =
      Messaging.create_federated_message(%{
        content: "Thread body",
        title: "Overview community thread",
        visibility: "public",
        post_type: "discussion",
        federated: true,
        activitypub_id: "https://community.example/post/#{unique}",
        activitypub_url: "https://community.example/post/#{unique}",
        remote_actor_id: remote_actor.id,
        media_metadata: %{"community_actor_uri" => "https://community.example/c/test"}
      })

    post = Repo.preload(post, [:link_preview, :conversation, remote_actor: []])

    html =
      render_component(ElektrineWeb.Components.Social.OverviewStreamPost,
        id: "overview-stream-post-#{post.id}",
        post: post,
        current_user: nil,
        timezone: "UTC",
        time_format: "12h",
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        user_statuses: %{},
        post_reactions: %{}
      )

    assert html =~ post.title
    assert html =~ ~s(id="lemmy-post-#{post.id}")
  end
end
