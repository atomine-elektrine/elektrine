defmodule ElektrineWeb.TimelinePostDetailTest do
  use ElektrineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging.Message
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social

  describe "image posts on timeline detail page" do
    test "renders an image-only local post", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "",
          visibility: "public",
          media_urls: ["timeline-attachments/test.jpg"]
        )

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/timeline/post/#{post.id}")
      assert redirect_to == ~p"/remote/post/#{post.id}"

      {:ok, _view, html} = live(conn, redirect_to)

      assert html =~ "/uploads/timeline-attachments/test.jpg"
    end

    test "does not crash when media_urls contains blank entries", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "",
          visibility: "public",
          media_urls: ["timeline-attachments/test.jpg"]
        )

      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [media_urls: ["", "timeline-attachments/test.jpg"]]
      )

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/timeline/post/#{post.id}")
      assert redirect_to == ~p"/remote/post/#{post.id}"

      {:ok, _view, html} = live(conn, redirect_to)

      assert html =~ "/uploads/timeline-attachments/test.jpg"
    end

    test "does not crash when cached replies metadata is a URL string", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "Cached post with replies URL", visibility: "public")

      activitypub_id = "https://popbob.wtf/notes/aio1kmd9jaat9rgd"

      Repo.update_all(
        from(m in Message, where: m.id == ^post.id),
        set: [
          activitypub_id: activitypub_id,
          media_metadata: %{
            "replies" => "#{activitypub_id}/replies",
            "replies_count" => "7"
          }
        ]
      )

      encoded_id = URI.encode_www_form(activitypub_id)
      assert {:ok, _view, _html} = live(conn, ~p"/remote/post/#{encoded_id}")
    end

    test "shows submitted link for cached federated link posts", %{conn: conn} do
      unique = System.unique_integer([:positive])
      activitypub_id = "https://feditown.com/post/#{unique}"
      submitted_url = "https://example.com/articles/#{unique}"

      remote_actor =
        %Actor{}
        |> Actor.changeset(%{
          uri: "https://feditown.com/u/poster-#{unique}",
          username: "poster#{unique}",
          domain: "feditown.com",
          inbox_url: "https://feditown.com/inbox",
          public_key: "test-public-key-#{unique}"
        })
        |> Repo.insert!()

      {:ok, _message} =
        Messaging.create_federated_message(%{
          content: "link submission",
          title: "A submitted link",
          visibility: "public",
          activitypub_id: activitypub_id,
          activitypub_url: activitypub_id,
          federated: true,
          remote_actor_id: remote_actor.id,
          media_metadata: %{"external_link" => submitted_url}
        })

      encoded_id = URI.encode_www_form(activitypub_id)
      {:ok, _view, html} = live(conn, ~p"/remote/post/#{encoded_id}")

      assert html =~ ~s(href="#{submitted_url}")
      assert html =~ "Open submitted link"
    end

    test "renders local post replies when remote actor is nil", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(user.id, "Parent local post", visibility: "public")

      {:ok, _reply} =
        Social.create_timeline_post(user.id, "Local reply content",
          visibility: "public",
          reply_to_id: post.id
        )

      {:ok, view, _initial_html} = live(conn, ~p"/remote/post/#{post.id}")

      assert render(view) =~ "Local reply content"
    end

    test "shows '(you)' only for replies written by the signed-in user", %{conn: conn} do
      post_author = AccountsFixtures.user_fixture()
      other_user = AccountsFixtures.user_fixture()
      viewer = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(post_author.id, "Parent local post", visibility: "public")

      {:ok, _other_reply} =
        Social.create_timeline_post(other_user.id, "Other user local reply",
          visibility: "public",
          reply_to_id: post.id
        )

      {:ok, _viewer_reply} =
        Social.create_timeline_post(viewer.id, "Viewer local reply",
          visibility: "public",
          reply_to_id: post.id
        )

      {:ok, view, _initial_html} =
        conn
        |> log_in_user(viewer)
        |> live(~p"/remote/post/#{post.id}")

      html = render(view)

      assert html =~ "Other user local reply"
      assert html =~ "Viewer local reply"
      assert html =~ "(you)"
      assert length(String.split(html, "(you)")) - 1 == 1
    end

    test "uses HTML profile routes for local usernames on post detail", %{conn: conn} do
      author = AccountsFixtures.user_fixture()

      {:ok, post} =
        Social.create_timeline_post(author.id, "Parent local post", visibility: "public")

      {:ok, _view, html} = live(conn, ~p"/remote/post/#{post.id}")

      assert html =~ "Parent local post"
      refute html =~ ~s(href="/users/#{author.username}")
    end

    test "shows recent replies in quick reply form for local posts", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, post} = Social.create_timeline_post(user.id, "Local post", visibility: "public")

      {:ok, _older_reply} =
        Social.create_timeline_post(user.id, "Older reply content",
          visibility: "public",
          reply_to_id: post.id
        )

      {:ok, _newer_reply} =
        Social.create_timeline_post(user.id, "Newer reply content",
          visibility: "public",
          reply_to_id: post.id
        )

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/remote/post/#{post.id}")

      _ = render_click(view, "toggle_reply_form")
      html = render(view)

      assert html =~ "Recent Replies:"
      assert html =~ "Older reply content"
      assert html =~ "Newer reply content"
    end

    test "supports inline nested replies for local comments", %{conn: conn} do
      author = AccountsFixtures.user_fixture()
      replier = AccountsFixtures.user_fixture()

      {:ok, post} = Social.create_timeline_post(author.id, "Local post", visibility: "public")

      {:ok, parent_reply} =
        Social.create_timeline_post(author.id, "Parent local reply",
          visibility: "public",
          reply_to_id: post.id
        )

      comment_id = "#{ElektrineWeb.Endpoint.url()}/posts/#{parent_reply.id}"

      {:ok, view, _html} =
        conn
        |> log_in_user(replier)
        |> live(~p"/remote/post/#{post.id}")

      _ = render_click(view, "toggle_comment_reply", %{"comment_id" => comment_id})

      _ =
        render_submit(view, "submit_comment_reply", %{
          "content" => "Nested inline reply content"
        })

      html = render(view)
      assert html =~ "Nested inline reply content"

      nested_reply =
        Message
        |> where(
          [m],
          m.sender_id == ^replier.id and m.reply_to_id == ^parent_reply.id and
            m.content == "Nested inline reply content"
        )
        |> Repo.one()

      assert nested_reply
    end
  end

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
