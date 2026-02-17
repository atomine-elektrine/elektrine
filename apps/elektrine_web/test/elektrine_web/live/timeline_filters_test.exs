defmodule ElektrineWeb.TimelineFiltersTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Elektrine.SocialFixtures

  alias Elektrine.AccountsFixtures
  alias Elektrine.Accounts.User
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "switching to posts view applies immediately when current filter is all", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, _regular_post} =
      Social.create_timeline_post(author.id, "Regular timeline post", visibility: "public")

    {:ok, _community_post} =
      Social.create_timeline_post(author.id, "Community timeline post",
        visibility: "public",
        community_actor_uri: "https://lemmy.world/c/elixir"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "2 shown"
    assert render(view) =~ "Regular timeline post"
    assert render(view) =~ "Community timeline post"

    render_hook(view, "filter_timeline", %{"filter" => "posts"})
    assert_patch(view, ~p"/timeline?filter=all&view=posts")

    html = render(view)

    assert html =~ "1 shown"
    assert html =~ "Regular timeline post"
    refute html =~ "Community timeline post"
  end

  test "my_posts view loads the signed-in user's dataset", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    viewer_timeline = timeline_conversation_fixture(viewer)
    other_timeline = timeline_conversation_fixture(other)

    _my_post =
      post_fixture(
        user: viewer,
        conversation: viewer_timeline,
        content: "My dedicated timeline post"
      )

    for i <- 1..25 do
      _post =
        post_fixture(
          user: other,
          conversation: other_timeline,
          content: "Other timeline post #{i}"
        )
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "filter_timeline", %{"filter" => "my_posts"})
    assert_patch(view, ~p"/timeline?filter=all&view=my_posts")

    html = render(view)
    assert html =~ "My dedicated timeline post"
    refute html =~ "Other timeline post 25"
  end

  test "trusted view only shows TL2+ local posts", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    trusted_author = AccountsFixtures.user_fixture()
    untrusted_author = AccountsFixtures.user_fixture()
    trusted_timeline = timeline_conversation_fixture(trusted_author)
    untrusted_timeline = timeline_conversation_fixture(untrusted_author)

    Repo.update_all(from(u in User, where: u.id == ^trusted_author.id), set: [trust_level: 2])
    Repo.update_all(from(u in User, where: u.id == ^untrusted_author.id), set: [trust_level: 1])

    _trusted_post =
      post_fixture(
        user: trusted_author,
        conversation: trusted_timeline,
        content: "Trusted timeline post"
      )

    _untrusted_post =
      post_fixture(
        user: untrusted_author,
        conversation: untrusted_timeline,
        content: "Untrusted timeline post"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "filter_timeline", %{"filter" => "trusted"})
    assert_patch(view, ~p"/timeline?filter=all&view=trusted")

    html = render(view)
    assert html =~ "Trusted timeline post"
    refute html =~ "Untrusted timeline post"
  end

  test "replies view only includes replies in federated threads", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()
    viewer_timeline = timeline_conversation_fixture(viewer)
    author_timeline = timeline_conversation_fixture(author)

    federated_parent =
      post_fixture(
        user: author,
        conversation: author_timeline,
        content: "Federated parent post"
      )

    Repo.update_all(
      from(m in Message, where: m.id == ^federated_parent.id),
      set: [federated: true]
    )

    local_parent =
      post_fixture(
        user: author,
        conversation: author_timeline,
        content: "Local parent post"
      )

    {:ok, _federated_reply} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: viewer_timeline.id,
        sender_id: viewer.id,
        content: "Reply to federated parent",
        message_type: "text",
        visibility: "public",
        post_type: "post",
        reply_to_id: federated_parent.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })
      |> Repo.insert()

    {:ok, _local_reply} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: viewer_timeline.id,
        sender_id: viewer.id,
        content: "Reply to local parent",
        message_type: "text",
        visibility: "public",
        post_type: "post",
        reply_to_id: local_parent.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })
      |> Repo.insert()

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "filter_timeline", %{"filter" => "replies"})
    assert_patch(view, ~p"/timeline?filter=all&view=replies")

    html = render(view)
    assert html =~ "Reply to federated parent"
    refute html =~ "Reply to local parent"
  end

  test "navigate_to_post routes federated posts to remote post detail", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Federated timeline post", visibility: "public")

    activitypub_id = "https://example.social/objects/#{post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^post.id),
      set: [federated: true, activitypub_id: activitypub_id]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Federated timeline post"

    render_hook(view, "navigate_to_post", %{"id" => to_string(post.id)})
    assert_redirect(view, "/remote/post/#{URI.encode_www_form(activitypub_id)}")
  end

  test "navigate_to_post routes local posts to timeline post detail", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Local timeline post", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Local timeline post"

    render_hook(view, "navigate_to_post", %{"id" => to_string(post.id)})
    assert_redirect(view, ~p"/timeline/post/#{post.id}")
  end

  test "new posts banner only appears for posts matching the active timeline view", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    {:ok, queued_post} =
      Social.create_timeline_post(author.id, "Queued post for all view", visibility: "public")

    queued_post =
      Repo.preload(queued_post, [:sender, :remote_actor, :link_preview, poll: [options: []]])

    send(view.pid, {:new_post_preloaded, :timeline, queued_post})
    assert render(view) =~ "Show 1 new post"

    render_hook(view, "filter_timeline", %{"filter" => "replies"})
    assert_patch(view, ~p"/timeline?filter=all&view=replies")

    refute render(view) =~ "Show 1 new post"
  end
end
