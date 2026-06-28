defmodule ElektrineWeb.PortalLiveTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Elektrine.SocialFixtures,
    only: [discussion_post_fixture: 1, media_post_fixture: 1, post_fixture: 1]

  alias Elektrine.{AccountsFixtures, Friends, Messaging, Profiles, Repo, RSS, Social}
  alias Elektrine.ActivityPub.Actor
  alias ElektrineWeb.PortalLive.Index

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

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  test "redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, reason} = live(conn, ~p"/portal")

    assert match?({:redirect, %{to: "/login"}}, reason) or
             match?({:live_redirect, %{to: "/login"}}, reason)
  end

  test "invalid filter param falls back to default portal content", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal?filter=not-real")

    assert has_element?(
             view,
             ~s(button[phx-click="set_filter"][phx-value-filter="all"].btn-secondary)
           )

    assert html =~ "0 posts"
  end

  test "loader log label formats tuple keys safely" do
    assert Index.loader_log_label({:for_you_feed, "all"}) == "{:for_you_feed, \"all\"}"
  end

  test "remote post navigation prefers local id over remote url", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    assert {:error, {:live_redirect, %{to: "/remote/post/2840437"}}} =
             render_hook(view, "navigate_to_remote_post", %{
               "id" => "2840437",
               "url" => "https://mastodon.online/users/mwichary/statuses/116636406552298995"
             })
  end

  test "shell prioritizes RSS reading controls", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal?filter=timeline")

    assert html =~ ~s(data-test="global-composer")
    assert html =~ "Feed Reader"
    assert html =~ "/settings/rss"
    refute html =~ "Your activity"
  end

  test "portal renders RSS items before the social feed", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed.xml")
    {:ok, feed} = RSS.update_feed(feed, %{title: "Example Feed", status: "active"})
    {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

    {:ok, _item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-rss-item",
        title: "Portal RSS headline",
        summary: "A useful article from a subscribed feed.",
        url: "https://example.com/articles/portal-rss-headline",
        published_at: DateTime.utc_now()
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    assert html =~ "Reading"
    assert html =~ "Portal RSS headline"
    assert html =~ "Example Feed"
    assert html =~ "A useful article from a subscribed feed."
    assert html =~ "Social feed"
  end

  test "portal RSS reader filters by source and previews full selected item", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, feed_a} = RSS.get_or_create_feed("https://example.com/feed-a.xml")
    {:ok, feed_a} = RSS.update_feed(feed_a, %{title: "Example A", status: "active"})
    {:ok, _subscription_a} = RSS.subscribe(user.id, feed_a.url)

    {:ok, feed_b} = RSS.get_or_create_feed("https://example.org/feed-b.xml")
    {:ok, feed_b} = RSS.update_feed(feed_b, %{title: "Example B", status: "active"})
    {:ok, _subscription_b} = RSS.subscribe(user.id, feed_b.url)

    {:ok, item_a} =
      RSS.upsert_item(feed_a.id, %{
        guid: "portal-reader-a",
        title: "Rust analysis roundup",
        summary: "Systems programming notes for the week.",
        content:
          "Full systems article body with enough detail to make the preview useful without opening the original.",
        url: "https://example.com/rust-analysis-roundup",
        image_url: "https://example.com/rust-analysis.jpg",
        author: "Ada",
        categories: ["systems"],
        published_at: ~U[2026-05-14 00:00:00Z]
      })

    {:ok, _item_b} =
      RSS.upsert_item(feed_b.id, %{
        guid: "portal-reader-b",
        title: "Garden planning dispatch",
        summary: "Plants, soil, and spring notes.",
        url: "https://example.org/garden-planning-dispatch",
        published_at: ~U[2026-05-13 00:00:00Z]
      })

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    assert html =~ ~s(data-role="rss-reader-list")
    assert html =~ "Rust analysis roundup"
    assert html =~ "Garden planning dispatch"
    assert html =~ "rss_item=#{item_a.id}"

    html =
      view
      |> element(~s(a[href*="rss_source=#{feed_b.id}"]))
      |> render_click()

    assert html =~ "Garden planning dispatch"
    refute html =~ "Rust analysis roundup"

    view
    |> element(~s(a[href*="rss_source=all"]), "All feeds")
    |> render_click()

    html =
      view
      |> element(~s([data-role="rss-reader-list"] a[href*="rss_item=#{item_a.id}"]))
      |> render_click()

    assert html =~ "Read original"
    assert html =~ "Full systems article body with enough detail"
    assert html =~ "background-image"
    assert html =~ "Ada"
    assert html =~ "systems"
  end

  test "portal RSS reader sanitizes selected item HTML", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed-security.xml")
    {:ok, feed} = RSS.update_feed(feed, %{title: "Security Feed", status: "active"})
    {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

    {:ok, item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-hostile-html",
        title: "Hostile RSS payload",
        content:
          ~s|<p>Visible text</p><script>alert(1)</script><img src="x" onerror="alert(2)"><a href="javascript:alert(3)">bad link</a>|,
        url: "https://example.com/hostile-rss-payload",
        published_at: ~U[2026-05-14 00:00:00Z]
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    html =
      view
      |> element(~s([data-role="rss-reader-list"] a[href*="rss_item=#{item.id}"]))
      |> render_click()

    assert html =~ "Visible text"
    refute html =~ "<script"
    refute html =~ "onerror"
    refute html =~ "javascript:alert"
  end

  test "portal RSS item selection does not reload the reader list", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, feed} = RSS.get_or_create_feed("https://example.com/stable-reader.xml")
    {:ok, feed} = RSS.update_feed(feed, %{title: "Stable Feed", status: "active"})
    {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

    {:ok, older_item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-stable-older",
        title: "Stable older item",
        content: "Stable older item body",
        url: "https://example.com/stable-older-item",
        published_at: ~U[2026-05-13 00:00:00Z]
      })

    {:ok, _newer_item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-stable-newer",
        title: "Stable newer item",
        content: "Stable newer item body",
        url: "https://example.com/stable-newer-item",
        published_at: ~U[2026-05-14 00:00:00Z]
      })

    {:ok, view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    assert html =~ "Stable older item"
    assert html =~ "Stable newer item"

    {:ok, _late_item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-late-newest",
        title: "Late newest item after render",
        content: "This should not appear from selecting an existing item.",
        url: "https://example.com/late-newest-item",
        published_at: ~U[2026-05-15 00:00:00Z]
      })

    html =
      view
      |> element(~s([data-role="rss-reader-list"] a[href*="rss_item=#{older_item.id}"]))
      |> render_click()

    assert html =~ "Stable older item body"
    refute html =~ "Late newest item after render"
  end

  test "portal RSS item links can select an item before LiveView click handlers attach", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed-links.xml")
    {:ok, feed} = RSS.update_feed(feed, %{title: "Link Feed", status: "active"})
    {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

    {:ok, item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-linkable",
        title: "Linkable item",
        summary: "Short summary",
        content: "Full linkable item body",
        url: "https://example.com/linkable-item",
        published_at: ~U[2026-05-14 00:00:00Z]
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal?rss_item=#{item.id}")

    assert html =~ "Full linkable item body"
    assert html =~ "rss_item=#{item.id}"
  end

  test "portal RSS item links can select an item outside the initial reader slice", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    {:ok, feed} = RSS.get_or_create_feed("https://example.com/feed-deep-links.xml")
    {:ok, feed} = RSS.update_feed(feed, %{title: "Deep Link Feed", status: "active"})
    {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

    for index <- 1..20 do
      {:ok, _item} =
        RSS.upsert_item(feed.id, %{
          guid: "portal-reader-newer-#{index}",
          title: "Newer item #{index}",
          url: "https://example.com/newer-item-#{index}",
          published_at: DateTime.add(~U[2026-05-14 00:00:00Z], index, :second)
        })
    end

    {:ok, item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-deep-linkable",
        title: "Deep linkable item",
        summary: "Short summary",
        content: "Full deep linkable item body",
        url: "https://example.com/deep-linkable-item",
        published_at: ~U[2026-05-13 00:00:00Z]
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal?rss_item=#{item.id}")

    assert html =~ "Deep linkable item"
    assert html =~ "Full deep linkable item body"
    assert html =~ "rss_item=#{item.id}"
  end

  test "portal RSS reader derives image backgrounds from existing item content", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    {:ok, feed} = RSS.get_or_create_feed("https://example.net/feed.xml")
    {:ok, feed} = RSS.update_feed(feed, %{title: "Image Feed", status: "active"})
    {:ok, _subscription} = RSS.subscribe(user.id, feed.url)

    {:ok, item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-content-image",
        title: "Article with inline image",
        content: ~s(<p>Article body</p><img src="/images/story.jpg" />),
        url: "https://example.net/posts/story",
        published_at: ~U[2026-05-14 00:00:00Z]
      })

    {:ok, hostile_item} =
      RSS.upsert_item(feed.id, %{
        guid: "portal-reader-css-image",
        title: "Article with hostile image URL",
        image_url: ~S|https://example.net/story.jpg");color:red;/*|,
        url: "https://example.net/posts/hostile-story",
        published_at: ~U[2026-05-15 00:00:00Z]
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    html =
      view
      |> element(~s([data-role="rss-reader-list"] a[href*="rss_item=#{item.id}"]))
      |> render_click()

    assert html =~ "Article with inline image"
    assert html =~ "https://example.net/images/story.jpg"
    assert html =~ "background-image"

    html =
      view
      |> element(~s([data-role="rss-reader-list"] a[href*="rss_item=#{hostile_item.id}"]))
      |> render_click()

    assert html =~ "Article with hostile image URL"
    assert html =~ ~S|https://example.net/story.jpg\&quot;);color:red;/*|
    refute html =~ ~S|url("https://example.net/story.jpg&quot;);color:red|
  end

  test "portal omits redundant recent activity card", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    refute has_element?(view, ~s([data-role="recent-activity-list"]))
    refute render(view) =~ "Recent Activity"
  end

  test "invalid like_post id does not crash and shows an error", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    render_hook(view, "like_post", %{"message_id" => "abc"})
    assert render(view) =~ "Invalid post id"
  end

  test "discussion cards on portal accept post_id for upvotes and downvotes", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()
    post = discussion_post_fixture(%{user: author, title: "Portal vote regression"})

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal?filter=discussions")

    assert has_element?(
             view,
             ~s(#lemmy-post-#{post.id} button[phx-click="like_post"][phx-value-post_id="#{post.id}"])
           )

    html = render_hook(view, "like_post", %{"post_id" => Integer.to_string(post.id)})

    assert html =~ ~s(id="lemmy-post-#{post.id}")
    assert html =~ ~s(phx-click="unlike_post")
    assert html =~ ~s(phx-value-post_id="#{post.id}")

    html = render_hook(view, "downvote_post", %{"post_id" => Integer.to_string(post.id)})

    assert html =~ ~s(id="lemmy-post-#{post.id}")
    assert html =~ ~s(phx-click="undownvote_post")
    assert html =~ ~s(aria-label="Score: -1")
    refute html =~ ~s(phx-click="unlike_post")
  end

  test "discussion feed is topped up with public community posts when personalized results are sparse" do
    community_metadata = %{"community_actor_uri" => "https://lemmy.world/c/test"}

    personalized_posts = [
      %{id: 1, media_metadata: community_metadata}
    ]

    public_posts = [
      %{id: 1, media_metadata: community_metadata},
      %{id: 2, media_metadata: community_metadata},
      %{id: 3, media_metadata: community_metadata}
    ]

    merged = Index.merge_discussion_feed_posts(personalized_posts, public_posts, 3)

    assert Enum.map(merged, & &1.id) == [1, 2, 3]
  end

  test "remote count refresh candidates are visible remote ActivityPub posts only" do
    posts = [
      %{id: 1, federated: true, remote_actor_id: 10, activitypub_id: "https://remote.test/1"},
      %{id: 1, federated: true, remote_actor_id: 10, activitypub_id: "https://remote.test/1"},
      %{id: 2, federated: false, remote_actor_id: 10, activitypub_id: "https://remote.test/2"},
      %{id: 3, federated: true, remote_actor_id: nil, activitypub_id: "https://remote.test/3"},
      %{id: 4, federated: true, remote_actor_id: 10, activitypub_id: ""},
      %{id: 5, federated: true, remote_actor_id: 11, activitypub_url: "https://remote.test/5"}
    ]

    assert Index.visible_remote_count_refresh_ids(posts, 10) == [1, 3, 5]
    assert Index.visible_remote_count_refresh_ids(posts, 1) == [1]
  end

  test "portal renders a taller loading shell before feed hydration", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/portal")
      |> html_response(200)

    assert html =~ ~s(phx-hook="TimelineReply")
    assert html =~ "space-y-4 min-h-[60vh]"
    assert html =~ "data-feed-loading-skeleton"
  end

  test "portal uses the infinite scroll feed container", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    assert has_element?(view, ~s(#portal-infinite-scroll[phx-hook="InfiniteScroll"]))
    assert has_element?(view, ~s(#portal-posts-list))
  end

  test "portal load replies shows a retry state when no replies are retrieved", %{conn: conn} do
    previous = Application.get_env(:elektrine, :recommendations_enabled, true)
    Application.put_env(:elektrine, :recommendations_enabled, false)
    on_exit(fn -> Application.put_env(:elektrine, :recommendations_enabled, previous) end)

    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Portal remote replies failure target",
        visibility: "public"
      )

    post =
      post
      |> Ecto.Changeset.change(%{
        reply_count: 2
      })
      |> Repo.update!()

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal?filter=timeline")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "Portal remote replies failure target" do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Portal remote replies failure target"

    html =
      view
      |> element(~s(button[phx-click="load_remote_replies"][phx-value-post_id="#{post.id}"]))
      |> render_click()

    assert html =~ "Could not load replies."
    assert html =~ "Try again"
  end

  test "portal feed loads older posts when infinite scroll requests more", %{conn: conn} do
    previous = Application.get_env(:elektrine, :recommendations_enabled, true)
    Application.put_env(:elektrine, :recommendations_enabled, false)
    on_exit(fn -> Application.put_env(:elektrine, :recommendations_enabled, previous) end)

    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    for index <- 1..25 do
      post_fixture(%{
        user: author,
        content: "Portal batch token #{String.pad_leading(Integer.to_string(index), 2, "0")}",
        visibility: "public"
      })
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal?filter=timeline")

    html =
      Enum.reduce_while(1..100, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "20 posts" and rendered =~ "Portal batch token 25" do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Portal batch token 25"
    refute html =~ "Portal batch token 01"

    render_hook(view, "load-more", %{})
    send(view.pid, {:load_more_feed, 40})

    html =
      Enum.reduce_while(1..100, html, fn _, _acc ->
        rendered = render(view)

        if rendered =~ "25 posts" and rendered =~ "Portal batch token 01" do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Portal batch token 25"
  end

  test "gallery filter fetches its own recommendation-backed feed", %{conn: conn} do
    previous = Application.get_env(:elektrine, :recommendations_enabled, true)
    Application.put_env(:elektrine, :recommendations_enabled, false)
    on_exit(fn -> Application.put_env(:elektrine, :recommendations_enabled, previous) end)

    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    gallery_post =
      media_post_fixture(%{
        user: author,
        content: "Portal gallery refresh token",
        media_urls: ["/uploads/portal-gallery-refresh.jpg"]
      })

    for index <- 1..25 do
      post_fixture(%{
        user: author,
        content:
          "Portal timeline fill token #{String.pad_leading(Integer.to_string(index), 2, "0")}",
        visibility: "public"
      })
    end

    {:ok, view, initial_html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal?filter=timeline")

    refute initial_html =~ gallery_post.content

    view
    |> element(~s(button[phx-click="set_filter"][phx-value-filter="gallery"]))
    |> render_click()

    assert_patch(view, ~p"/portal?filter=gallery&attention=all")

    html =
      Enum.reduce_while(1..100, "", fn _, _acc ->
        rendered = render(view)

        if rendered =~ gallery_post.content do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Gallery"
    assert html =~ gallery_post.content
    refute html =~ "Portal timeline fill token 25"
  end

  test "activity inspector can open the current user's following list", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    followed_user = AccountsFixtures.user_fixture()

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, followed_user.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal")

    send(view.pid, :load_stats_data)
    render(view)

    render_click(view, "inspect_activity", %{"section" => "following"})

    assert render(view) =~ "Following"
    assert render(view) =~ "@#{followed_user.handle || followed_user.username}"
  end

  test "activity metric cards are not rendered on the reading-first portal", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    send(view.pid, :load_stats_data)
    render(view)

    refute has_element?(view, ~s(button[phx-click="inspect_activity"][phx-value-section="posts"]))
    refute has_element?(view, ~s(button[data-action="show-followers"]))
    refute has_element?(view, ~s(button[data-action="show-following"]))
  end

  test "posts inspector paginates larger activity lists", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    for index <- 1..30 do
      post_fixture(%{
        user: user,
        content:
          "Inspector activity token #{String.pad_leading(Integer.to_string(index), 2, "0")}",
        visibility: "public"
      })
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/portal")

    send(view.pid, :load_stats_data)
    render(view)

    render_click(view, "inspect_activity", %{"section" => "posts"})

    html = render(view)

    assert html =~ "Posts"
    assert html =~ "Inspector activity token 30"
    assert count_occurrences(html, ~s(data-role="activity-entry")) == 25

    assert has_element?(
             view,
             ~s([data-role="activity-inspector"] button[phx-click="load_more_activity"])
           )

    view
    |> element(~s(button[phx-click="load_more_activity"]))
    |> render_click()

    html = render(view)

    assert html =~ "Inspector activity token 30"
    assert html =~ "Inspector activity token 05"
    assert count_occurrences(html, ~s(data-role="activity-entry")) == 30
  end

  test "unfollowing from portal does not crash when the follow exists", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, _post} =
      Social.create_timeline_post(author.id, "Portal follow regression target",
        visibility: "public"
      )

    assert {:ok, _follow} = Profiles.follow_user(viewer.id, author.id)

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "Portal follow regression target" and
             has_element?(
               view,
               ~s(#portal-posts-list button[data-follow-variant="timeline"][phx-click="toggle_follow"][phx-value-user_id="#{author.id}"]),
               "Unfollow"
             ) do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Portal follow regression target"
    assert Profiles.following?(viewer.id, author.id)

    view
    |> element(
      ~s(#portal-posts-list button[data-follow-variant="timeline"][phx-click="toggle_follow"][phx-value-user_id="#{author.id}"])
    )
    |> render_click()

    refute Profiles.following?(viewer.id, author.id)

    assert has_element?(
             view,
             ~s(#portal-posts-list button[data-follow-variant="timeline"][phx-click="toggle_follow"][phx-value-user_id="#{author.id}"]),
             "Follow"
           )
  end

  test "not interested removes a post from the portal feed", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Portal dismissal target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/portal")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        send(view.pid, :load_feed_data)
        rendered = render(view)

        if rendered =~ "Portal dismissal target" and
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

    assert html =~ "Portal dismissal target"

    view
    |> element(~s(button[phx-click="not_interested"][phx-value-post_id="#{post.id}"]))
    |> render_click()

    refute render(view) =~ "Portal dismissal target"
  end

  test "portal renders community posts with the same lemmy layout as timeline", %{conn: _conn} do
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
        title: "Portal community thread",
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
      render_component(ElektrineSocialWeb.Components.Social.TimelineStreamPost,
        id: "portal-stream-post-#{post.id}",
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
