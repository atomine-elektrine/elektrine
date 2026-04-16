defmodule ElektrineSocialWeb.TimelineFiltersTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts.User
  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social

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

  defp remote_actor_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        uri: "https://remote.example/users/remote#{unique}",
        username: "remote#{unique}",
        domain: "remote.example",
        display_name: "Remote #{unique}",
        inbox_url: "https://remote.example/inbox",
        public_key: "test-public-key-#{unique}"
      })

    %Actor{}
    |> Actor.changeset(attrs)
    |> Repo.insert!()
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
    assert_patch(view, ~p"/timeline?filter=explore&view=posts")

    html = render(view)

    assert html =~ "1 shown"
    assert html =~ "Regular timeline post"
    refute html =~ "Community timeline post"
  end

  test "software filters keep local posts and communities visible", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, _local_post} =
      Social.create_timeline_post(author.id, "Local timeline post", visibility: "public")

    {:ok, _community_post} =
      Social.create_timeline_post(author.id, "Local community post",
        visibility: "public",
        community_actor_uri: "https://elektrine.example/c/local"
      )

    remote_actor = remote_actor_fixture(%{domain: "mastodon.example"})

    {:ok, _federated_post} =
      Messaging.create_federated_message(%{
        remote_actor_id: remote_actor.id,
        content: "Remote mastodon post",
        visibility: "public",
        federated: true,
        activitypub_id: "https://mastodon.example/users/alice/statuses/1",
        activitypub_url: "https://mastodon.example/users/alice/statuses/1"
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "set_software_filter", %{"software" => "mastodon"})

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        rendered = render(view)

        if rendered =~ "Local timeline post" && rendered =~ "Local community post" do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Local timeline post"
    assert html =~ "Local community post"
  end

  test "composer character counter updates immediately while typing", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "toggle_post_composer", %{})
    assert render(view) =~ "0/3 min"

    render_hook(view, "update_post_content_live", %{"value" => "typed live"})
    assert render(view) =~ "10/3 min"
  end

  test "clearing the sidebar search removes the query from the URL", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, _post} =
      Social.create_timeline_post(author.id, "Clear search target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all&q=target")

    assert has_element?(
             view,
             "#timeline-left-sidebar-search button[phx-click=\"clear_search\"]"
           )

    view
    |> element("#timeline-left-sidebar-search button[phx-click=\"clear_search\"]")
    |> render_click()

    assert_patch(view, ~p"/timeline?filter=explore&view=all")
  end

  test "quick reply character counter updates immediately while typing", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Quick reply counter target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "show_reply_form", %{"message_id" => to_string(post.id)})
    assert render(view) =~ "0/3 required chars"

    assert has_element?(
             view,
             "#reply-textarea-#{post.id}[data-live-update-event=\"update_reply_content\"]"
           )

    textarea = element(view, "#reply-textarea-#{post.id}")

    assert render_hook(textarea, "update_reply_content", %{"value" => "typed live"}) =~
             "10/3 required chars"
  end

  test "replying to a thread reply hides the post-level quick reply form", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Thread root", visibility: "public")

    {:ok, reply} =
      Social.create_timeline_post(author.id, "Thread reply",
        visibility: "public",
        reply_to_id: post.id
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "show_reply_form", %{"message_id" => to_string(post.id)})
    assert has_element?(view, "#reply-form-#{post.id}")
    assert has_element?(view, ~s(input[name="reply_to_id"][value="#{post.id}"]))

    render_hook(view, "show_reply_to_reply_form", %{
      "reply_id" => to_string(reply.id),
      "post_id" => to_string(post.id)
    })

    refute has_element?(view, "#reply-form-#{post.id}")
    refute has_element?(view, ~s(input[name="reply_to_id"][value="#{post.id}"]))
    assert has_element?(view, ~s(input[name="reply_to_id"][value="#{reply.id}"]))
  end

  test "timeline reserves image space from attachment metadata", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()
    media_key = "timeline-attachments/#{author.id}_test-image.png"

    {:ok, post} =
      Social.create_timeline_post(author.id, "Metadata-backed media post",
        visibility: "public",
        media_urls: [media_key]
      )

    from(m in Message, where: m.id == ^post.id)
    |> Repo.update_all(
      set: [
        media_metadata: %{
          "attachments" => [
            %{
              "url" => media_key,
              "mime_type" => "image/png",
              "width" => 640,
              "height" => 480
            }
          ]
        }
      ]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=explore&view=all")

    html =
      Enum.reduce_while(1..40, "", fn _, _acc ->
        rendered = render(view)

        if rendered =~ "Metadata-backed media post" &&
             has_element?(
               view,
               ~s(button[style*="aspect-ratio"])
             ) do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert html =~ "Metadata-backed media post"

    assert has_element?(
             view,
             ~s(button[style*="aspect-ratio"])
           )

    assert html =~ ~r/aspect-ratio:\s*640\s*\/\s*480/
  end

  test "saving a timeline post immediately flips the bookmark button to solid", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Save interaction target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Save interaction target"

    assert has_element?(
             view,
             ~s(button[phx-click="save_post"][phx-value-message_id="#{post.id}"] .hero-bookmark)
           )

    render_hook(view, "save_post", %{"message_id" => Integer.to_string(post.id)})

    assert Social.post_saved?(viewer.id, post.id)

    assert has_element?(
             view,
             ~s(button[phx-click="unsave_post"][phx-value-message_id="#{post.id}"] .hero-bookmark-solid)
           )
  end

  test "liking a timeline post immediately flips the heart button to solid", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Like interaction target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Like interaction target"

    assert has_element?(
             view,
             ~s(button[phx-click="like_post"][phx-value-message_id="#{post.id}"] .hero-heart)
           )

    assert has_element?(
             view,
             ~s(button[phx-click="like_post"][phx-value-message_id="#{post.id}"] span),
             "0"
           )

    render_hook(view, "like_post", %{"message_id" => Integer.to_string(post.id)})

    assert Social.user_liked_post?(viewer.id, post.id)

    assert has_element?(
             view,
             ~s(button[phx-click="unlike_post"][phx-value-message_id="#{post.id}"] .hero-heart-solid)
           )

    assert has_element?(
             view,
             ~s(button[phx-click="unlike_post"][phx-value-message_id="#{post.id}"] span),
             "1"
           )
  end

  test "boosting a timeline post immediately flips the repost button to solid", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Boost interaction target", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Boost interaction target"

    assert has_element?(
             view,
             ~s(button[phx-click="boost_post"][phx-value-message_id="#{post.id}"] .hero-arrow-path)
           )

    render_hook(view, "boost_post", %{"message_id" => Integer.to_string(post.id)})

    assert Social.user_boosted?(viewer.id, post.id)

    assert has_element?(
             view,
             ~s(button[phx-click="unboost_post"][phx-value-message_id="#{post.id}"] .hero-arrow-path-solid)
           )
  end

  test "suggested follows use the same local follow button path", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    suggestion = AccountsFixtures.user_fixture()

    {:ok, _post} =
      Social.create_timeline_post(
        suggestion.id,
        "Suggested follow target",
        visibility: "public"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    selector = "#suggested-follow-#{suggestion.id}"

    assert render(view) =~ "Suggested Follows"
    assert has_element?(view, selector)
    assert has_element?(view, ~s(#{selector}[phx-click="toggle_follow"]), "Follow")
    refute has_element?(view, ~s(#{selector}[phx-click="follow_suggested_user"]))

    view
    |> element(selector)
    |> render_click()

    assert Social.following?(viewer.id, suggestion.id)
    refute has_element?(view, selector)
  end

  test "remote follow button stays requested until follow acceptance arrives", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    actor = remote_actor_fixture()
    actor_id = actor.id
    unique = System.unique_integer([:positive])

    {:ok, _message} =
      Messaging.create_federated_message(%{
        content: "Remote follow target #{unique}",
        visibility: "public",
        activitypub_id: "https://remote.example/objects/#{unique}",
        activitypub_url: "https://remote.example/objects/#{unique}",
        federated: true,
        remote_actor_id: actor.id
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    selector =
      ~s(button[phx-click="toggle_follow_remote"][phx-value-remote_actor_id="#{actor_id}"])

    assert render(view) =~ "Remote follow target #{unique}"
    assert has_element?(view, selector, "Follow")
    assert_remote_follow_markup(render(view), selector)

    view
    |> element(selector)
    |> render_click()

    assert_remote_follow_markup(render(view), selector)

    assert_push_event(view, "remote_follow_state_changed", %{
      remote_actor_id: ^actor_id,
      state: "pending"
    })

    assert %Elektrine.Profiles.Follow{pending: true} =
             Elektrine.Profiles.get_follow_to_remote_actor(viewer.id, actor_id)

    send(view.pid, {:follow_accepted, actor_id})

    assert_push_event(view, "remote_follow_state_changed", %{
      remote_actor_id: ^actor_id,
      state: "following"
    })
  end

  defp assert_remote_follow_markup(html, selector) do
    document = Floki.parse_document!(html)
    buttons = Floki.find(document, selector)

    assert buttons != []

    Enum.each(buttons, fn button ->
      button
      |> Floki.find("[data-follow-display]")
      |> Enum.each(fn state_node ->
        classes = state_node |> Floki.attribute("class") |> List.first() |> to_class_tokens()

        refute "inline-flex" in classes
      end)
    end)
  end

  defp to_class_tokens(nil), do: []

  defp to_class_tokens(classes) do
    classes
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  test "note composer route opens a private note template", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?composer=note")

    html = render(view)

    assert html =~ "New note"
    assert html =~ "Capture a private note"
    assert html =~ ~s(id="timeline-visibility-select")
    assert html =~ ~s(name="visibility")
    assert html =~ ~s(value="private")
  end

  test "search_timeline handles value payloads from input events", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()
    other_author = AccountsFixtures.user_fixture()

    {:ok, _post} =
      Social.create_timeline_post(
        author.id,
        "Search payload compatibility post",
        visibility: "public"
      )

    {:ok, _other_post} =
      Social.create_timeline_post(
        other_author.id,
        "Completely unrelated timeline post",
        visibility: "public"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Search payload compatibility post"

    render_hook(view, "search_timeline", %{"value" => "no-such-fragment"})
    assert_patch(view, "/timeline?filter=explore&q=no-such-fragment&view=all")
    assert render(view) =~ "No matching posts"

    render_hook(view, "search_timeline", %{"value" => "compatibility"})
    assert_patch(view, "/timeline?filter=explore&q=compatibility&view=all")
    assert render(view) =~ "Search payload compatibility post"
    refute render(view) =~ "Completely unrelated timeline post"

    send(
      view.pid,
      {:post_counts_updated,
       %{message_id: 999_999, counts: %{like_count: 0, share_count: 0, reply_count: 0}}}
    )

    html = render(view)
    assert html =~ "Search payload compatibility post"
    refute html =~ "Completely unrelated timeline post"
  end

  test "timeline search form filters the default home feed", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    matched_author = AccountsFixtures.user_fixture()
    other_author = AccountsFixtures.user_fixture()

    {:ok, _follow} = Social.follow_user(viewer.id, matched_author.id)
    {:ok, _follow} = Social.follow_user(viewer.id, other_author.id)

    {:ok, _matched_post} =
      Social.create_timeline_post(
        matched_author.id,
        "Home feed compatibility search post",
        visibility: "public"
      )

    {:ok, _other_post} =
      Social.create_timeline_post(
        other_author.id,
        "Home feed unrelated post",
        visibility: "public"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline")

    html = render(view)
    assert html =~ "Home feed compatibility search post"
    assert html =~ "Home feed unrelated post"

    view
    |> form("#timeline-left-sidebar-search", %{"query" => "compatibility"})
    |> render_change()

    assert_patch(view, "/timeline?filter=home&q=compatibility&view=all")

    html = render(view)
    assert html =~ "Home feed compatibility search post"
    refute html =~ "Home feed unrelated post"
  end

  test "signed-in timeline defaults to the home feed", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    followed_author = AccountsFixtures.user_fixture()
    stranger = AccountsFixtures.user_fixture()

    {:ok, _follow} = Social.follow_user(viewer.id, followed_author.id)

    {:ok, _followed_post} =
      Social.create_timeline_post(followed_author.id, "Post from followed user",
        visibility: "public"
      )

    {:ok, _stranger_post} =
      Social.create_timeline_post(stranger.id, "Public explore-only post", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline")

    html = render(view)
    assert html =~ "Post from followed user"
    refute html =~ "Public explore-only post"
  end

  test "for_you feed uses personalized recommendations", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    followed_author = AccountsFixtures.user_fixture()
    stranger = AccountsFixtures.user_fixture()

    {:ok, _follow} = Social.follow_user(viewer.id, followed_author.id)

    {:ok, _recommended_post} =
      Social.create_timeline_post(followed_author.id, "Recommended for you post",
        visibility: "public"
      )

    {:ok, _stranger_post} =
      Social.create_timeline_post(stranger.id, "Stranger post without signals",
        visibility: "public"
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=for_you&view=all")

    html = render(view)
    assert html =~ "Recommended for you post"
    refute html =~ "Stranger post without signals"
  end

  test "friends filter is visible in disconnected render when user has friends", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    friend = AccountsFixtures.user_fixture()

    {:ok, request} = Friends.send_friend_request(viewer.id, friend.id)
    {:ok, _accepted_request} = Friends.accept_friend_request(request.id, friend.id)

    html =
      conn
      |> log_in_user(viewer)
      |> get(~p"/timeline")
      |> html_response(200)

    assert html =~ ~s(phx-value-filter="friends")
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
    assert_patch(view, ~p"/timeline?filter=explore&view=my_posts")

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
    assert_patch(view, ~p"/timeline?filter=explore&view=trusted")

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
    assert_patch(view, ~p"/timeline?filter=explore&view=replies")

    html = render(view)
    assert html =~ "Reply to federated parent"
    refute html =~ "Reply to local parent"
  end

  test "federated replies view excludes local replies to federated threads", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()
    viewer_timeline = timeline_conversation_fixture(viewer)
    author_timeline = timeline_conversation_fixture(author)
    remote_actor = remote_actor_fixture(%{domain: "mastodon.example"})

    federated_parent =
      post_fixture(
        user: author,
        conversation: author_timeline,
        content: "Federated parent for source filter"
      )

    parent_ref = "https://mastodon.example/users/alice/statuses/#{federated_parent.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^federated_parent.id),
      set: [federated: true, activitypub_id: parent_ref, activitypub_url: parent_ref]
    )

    {:ok, _local_reply} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: viewer_timeline.id,
        sender_id: viewer.id,
        content: "Local reply to federated parent",
        message_type: "text",
        visibility: "public",
        post_type: "post",
        reply_to_id: federated_parent.id,
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })
      |> Repo.insert()

    {:ok, _remote_reply} =
      Messaging.create_federated_message(%{
        remote_actor_id: remote_actor.id,
        content: "Remote mastodon reply",
        visibility: "public",
        federated: true,
        activitypub_id:
          "https://mastodon.example/users/alice/statuses/reply-#{System.unique_integer([:positive])}",
        activitypub_url:
          "https://mastodon.example/users/alice/statuses/reply-url-#{System.unique_integer([:positive])}",
        media_metadata: %{"inReplyTo" => parent_ref}
      })

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=federated&view=replies")

    html = render(view)
    assert html =~ "Remote mastodon reply"
    refute html =~ "Local reply to federated parent"
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

  test "navigate_to_post opens parent thread for local replies", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, parent_post} =
      Social.create_timeline_post(author.id, "Parent post", visibility: "public")

    {:ok, reply_post} =
      Social.create_timeline_post(author.id, "Reply post",
        visibility: "public",
        reply_to_id: parent_post.id
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "navigate_to_post", %{"id" => to_string(reply_post.id)})
    assert_redirect(view, "/remote/post/#{parent_post.id}#message-#{reply_post.id}")
  end

  test "navigate_to_post opens metadata parent thread for federated replies", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, reply_post} =
      Social.create_timeline_post(author.id, "Federated reply post", visibility: "public")

    parent_ref = "https://example.social/notes/parent-#{reply_post.id}"
    reply_ref = "https://example.social/notes/reply-#{reply_post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^reply_post.id),
      set: [
        federated: true,
        activitypub_id: reply_ref,
        media_metadata: %{"inReplyTo" => parent_ref}
      ]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    render_hook(view, "navigate_to_post", %{"id" => to_string(reply_post.id)})

    assert_redirect(
      view,
      "/remote/post/#{URI.encode_www_form(parent_ref)}#message-#{reply_post.id}"
    )
  end

  test "timeline replies render ancestor context stack cards", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, root_post} =
      Social.create_timeline_post(author.id, "Root ancestor context", visibility: "public")

    {:ok, middle_post} =
      Social.create_timeline_post(author.id, "Middle ancestor context",
        visibility: "public",
        reply_to_id: root_post.id
      )

    root_ref = "https://example.social/objects/root-#{root_post.id}"
    middle_ref = "https://example.social/objects/middle-#{middle_post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^root_post.id),
      set: [federated: true, activitypub_id: root_ref]
    )

    Repo.update_all(
      from(m in Message, where: m.id == ^middle_post.id),
      set: [
        federated: true,
        activitypub_id: middle_ref,
        media_metadata: %{"inReplyTo" => root_ref}
      ]
    )

    {:ok, _leaf_reply} =
      Social.create_timeline_post(author.id, "Leaf reply in thread",
        visibility: "public",
        reply_to_id: middle_post.id
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=explore&view=replies")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        rendered = render(view)

        if rendered =~ "Leaf reply in thread" do
          {:halt, rendered}
        else
          Process.sleep(100)
          {:cont, rendered}
        end
      end)

    assert html =~ "Leaf reply in thread"
    assert html =~ "Conversation context"
    assert html =~ "Earlier context"
    assert html =~ "Replying to"
    assert html =~ "Root ancestor context"
    assert html =~ "Middle ancestor context"
    assert html =~ ~s(phx-value-id="#{root_post.id}")
    assert html =~ ~s(phx-value-id="#{middle_post.id}")
  end

  test "timeline thread context renders local custom emojis for local ancestors", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    %CustomEmoji{}
    |> CustomEmoji.changeset(%{
      shortcode: "thumbsupcat",
      image_url: "https://cdn.example/emojis/thumbsupcat.png",
      instance_domain: nil,
      visible_in_picker: false,
      disabled: false
    })
    |> Repo.insert!()

    {:ok, root_post} =
      Social.create_timeline_post(author.id, "Root ancestor :thumbsupcat:", visibility: "public")

    {:ok, middle_post} =
      Social.create_timeline_post(author.id, "Middle ancestor :thumbsupcat:",
        visibility: "public",
        reply_to_id: root_post.id
      )

    local_domain = Elektrine.Domains.instance_domain()
    root_ref = "https://#{local_domain}/objects/root-#{root_post.id}"
    middle_ref = "https://#{local_domain}/objects/middle-#{middle_post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^root_post.id),
      set: [federated: true, activitypub_id: root_ref]
    )

    Repo.update_all(
      from(m in Message, where: m.id == ^middle_post.id),
      set: [
        federated: true,
        activitypub_id: middle_ref,
        media_metadata: %{"inReplyTo" => root_ref}
      ]
    )

    {:ok, _leaf_reply} =
      Social.create_timeline_post(author.id, "Leaf reply in emoji thread",
        visibility: "public",
        reply_to_id: middle_post.id
      )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=replies")

    html =
      Enum.reduce_while(1..20, "", fn _, _acc ->
        rendered = render(view)

        if rendered =~ "Leaf reply in emoji thread" do
          {:halt, rendered}
        else
          Process.sleep(100)
          {:cont, rendered}
        end
      end)

    assert html =~ "Root ancestor"
    assert html =~ "Middle ancestor"
    assert html =~ "custom-emoji"
    assert html =~ "thumbsupcat.png"
  end

  test "load_remote_replies keeps loading until ingested replies are available", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Federated timeline post", visibility: "public")

    activitypub_id = "urn:ap:object:#{post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^post.id),
      set: [federated: true, activitypub_id: activitypub_id, reply_count: 2]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=explore&view=all")

    view
    |> element(~s(button[phx-click="load_remote_replies"][phx-value-post_id="#{post.id}"]))
    |> render_click()

    loading_html =
      Enum.reduce_while(1..10, "", fn _, _acc ->
        rendered = render(view)

        if rendered =~ "Loading replies..." do
          {:halt, rendered}
        else
          Process.sleep(50)
          {:cont, rendered}
        end
      end)

    assert loading_html =~ "Loading replies..."

    {:ok, _reply} =
      Social.create_timeline_post(author.id, "Reply imported from remote",
        visibility: "public",
        reply_to_id: post.id
      )

    send(view.pid, {:refresh_remote_replies, post.id, 1})

    _ = render(view)
    html = render(view)
    assert html =~ "Reply imported from remote"
    refute html =~ "Loading replies..."
  end

  test "load_remote_replies clears loading after retry limit when no replies arrive", %{
    conn: conn
  } do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Federated timeline post", visibility: "public")

    activitypub_id = "urn:ap:object:#{post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^post.id),
      set: [federated: true, activitypub_id: activitypub_id, reply_count: 2]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    view
    |> element(~s(button[phx-click="load_remote_replies"][phx-value-post_id="#{post.id}"]))
    |> render_click()

    send(view.pid, {:refresh_remote_replies, post.id, 6})

    html = render(view)
    assert html =~ "Load replies"
    refute html =~ "Loading replies..."
  end

  test "federated post count updates do not crash when lemmy counts are partial", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Federated count update target",
        visibility: "public"
      )

    activitypub_id = "urn:ap:object:#{post.id}"

    Repo.update_all(
      from(m in Message, where: m.id == ^post.id),
      set: [federated: true, activitypub_id: activitypub_id]
    )

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=federated&view=all")

    send(
      view.pid,
      {:post_counts_updated,
       %{message_id: post.id, counts: %{like_count: 1, reply_count: 0, share_count: 0}}}
    )

    html = render(view)
    assert html =~ "Federated count update target"
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
    html = render(view)
    assert html =~ "Show 1 new post"
    assert html =~ ~s(data-load-queued-posts)
    assert html =~ ~s(type="button")
    assert html =~ ~s(phx-hook="PreserveQueuedPostsButtonScroll")

    render_hook(view, "filter_timeline", %{"filter" => "replies"})
    assert_patch(view, ~p"/timeline?filter=explore&view=replies")

    refute render(view) =~ "Show 1 new post"
  end

  test "load more appends older posts without a full reload", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()
    author_timeline = timeline_conversation_fixture(author)

    for i <- 1..25 do
      _post =
        post_fixture(
          user: author,
          conversation: author_timeline,
          content: "Load more timeline post #{i}"
        )
    end

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    initial_html = render(view)
    assert initial_html =~ "Load More"
    assert initial_html =~ ~s(button type="button" phx-click="load_more_posts")
    refute initial_html =~ "Load more timeline post 25"

    html =
      view
      |> element("button[phx-click='load_more_posts']")
      |> render_click()

    assert html =~ "Load more timeline post 25"
  end

  test "hide_post removes the post from the timeline immediately", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture()
    author = AccountsFixtures.user_fixture()

    {:ok, post} =
      Social.create_timeline_post(author.id, "Hide me from timeline", visibility: "public")

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/timeline?filter=all&view=all")

    assert render(view) =~ "Hide me from timeline"

    view
    |> element("button[phx-click='hide_post'][phx-value-post_id='#{post.id}']")
    |> render_click()

    html = render(view)
    refute html =~ "Hide me from timeline"
    assert html =~ "Post hidden from your timeline."
  end
end
