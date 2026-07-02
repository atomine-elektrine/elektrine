defmodule ElektrineWeb.API.TimelineControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social.{Conversation, ConversationMember}
  alias ElektrineWeb.API.TimelineController

  describe "home/2" do
    test "lists posts from followed users only", %{conn: conn} do
      viewer = user_fixture()
      followed_author = user_fixture(%{username: "followedauthor"})
      followed_author_follower = user_fixture(%{username: "followedauthorfollower"})
      followed_by_author = user_fixture(%{username: "followedbyauthor"})
      other_author = user_fixture(%{username: "otherauthor"})

      followed_post =
        post_fixture(%{user: followed_author, content: "followed post", visibility: "public"})

      _other_post =
        post_fixture(%{user: other_author, content: "other post", visibility: "public"})

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, followed_author.id)

      assert {:ok, _follow} =
               Profiles.follow_user(followed_author_follower.id, followed_author.id)

      assert {:ok, _follow} = Profiles.follow_user(followed_author.id, followed_by_author.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TimelineController.home(%{})

      assert [
               %{
                 "id" => id,
                 "content" => "followed post",
                 "account" => %{
                   "followers_count" => 2,
                   "following_count" => 1,
                   "statuses_count" => 1
                 }
               }
             ] = json_response(conn, 200)

      assert id == to_string(followed_post.id)
    end

    test "supports max_id pagination" do
      viewer = user_fixture()
      author = user_fixture()

      older = post_fixture(%{user: author, content: "older home post"})
      newer = post_fixture(%{user: author, content: "newer home post"})

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, author.id)

      conn =
        build_conn(:get, "/api/v1/timelines/home?limit=1")
        |> assign(:current_user, viewer)
        |> TimelineController.home(%{"limit" => "1", "max_id" => to_string(newer.id)})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(older.id)
      assert [link] = get_resp_header(conn, "link")
      assert link =~ ~s(rel="next")
      assert link =~ ~s(rel="prev")
      assert link =~ "/api/v1/timelines/home?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/timelines/home?limit=1&since_id=#{older.id}"
    end
  end

  describe "direct/2" do
    test "lists visible direct posts only", %{conn: conn} do
      viewer = user_fixture(%{username: "directviewer"})
      other_author = user_fixture(%{username: "directother"})

      direct_post =
        post_fixture(%{user: viewer, content: "my direct api post", visibility: "direct"})

      _public_post =
        post_fixture(%{user: viewer, content: "my public api post", visibility: "public"})

      _other_direct_post =
        post_fixture(%{
          user: other_author,
          content: "other direct api post",
          visibility: "direct"
        })

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TimelineController.direct(%{})

      assert [%{"id" => id, "content" => "my direct api post", "visibility" => "direct"}] =
               json_response(conn, 200)

      assert id == to_string(direct_post.id)
    end

    test "lists direct posts from conversations the user belongs to", %{conn: conn} do
      viewer = user_fixture(%{username: "directrecipient"})
      author = user_fixture(%{username: "directsender"})
      stranger = user_fixture(%{username: "directstranger"})

      dm = social_dm_conversation_fixture(author, viewer)

      direct_post =
        post_fixture(%{
          user: author,
          conversation: dm,
          content: "recipient-visible direct post",
          visibility: "direct"
        })

      _stranger_post =
        post_fixture(%{
          user: author,
          content: "stranger-hidden direct post",
          visibility: "direct"
        })

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TimelineController.direct(%{})

      assert [%{"id" => id, "content" => "recipient-visible direct post"}] =
               json_response(conn, 200)

      assert id == to_string(direct_post.id)

      conn =
        build_conn()
        |> assign(:current_user, stranger)
        |> TimelineController.direct(%{})

      assert [] = json_response(conn, 200)
    end

    test "supports max_id pagination" do
      viewer = user_fixture()

      older = post_fixture(%{user: viewer, content: "older direct post", visibility: "direct"})
      newer = post_fixture(%{user: viewer, content: "newer direct post", visibility: "direct"})

      conn =
        build_conn(:get, "/api/v1/timelines/direct?limit=1")
        |> assign(:current_user, viewer)
        |> TimelineController.direct(%{"limit" => "1", "max_id" => to_string(newer.id)})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(older.id)
      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/timelines/direct?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/timelines/direct?limit=1&since_id=#{older.id}"
    end
  end

  defp social_dm_conversation_fixture(user, other_user) do
    conversation =
      %Conversation{}
      |> Conversation.dm_changeset(%{creator_id: user.id})
      |> Repo.insert!()

    ConversationMember.add_member_changeset(conversation.id, user.id)
    |> Repo.insert!()

    ConversationMember.add_member_changeset(conversation.id, other_user.id)
    |> Repo.insert!()

    conversation
  end

  describe "public/2" do
    test "lists public posts and excludes non-public posts", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture(%{username: "publicauthor"})

      public_post =
        post_fixture(%{user: author, content: "public api post", visibility: "public"})

      _private_post =
        post_fixture(%{user: author, content: "private api post", visibility: "private"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TimelineController.public(%{})

      assert [%{"id" => id, "content" => "public api post", "account" => %{"remote" => false}}] =
               json_response(conn, 200)

      assert id == to_string(public_post.id)
    end

    test "supports only_media filtering", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()

      media =
        media_post_fixture(%{
          user: author,
          content: "public media post",
          media_urls: ["/uploads/timeline-photo.jpg"]
        })

      _text = post_fixture(%{user: author, content: "plain public post", visibility: "public"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TimelineController.public(%{"only_media" => "true"})

      assert [%{"id" => id, "content" => "public media post"}] = json_response(conn, 200)
      assert id == to_string(media.id)
    end

    test "supports max_id pagination" do
      viewer = user_fixture()
      author = user_fixture()

      older = post_fixture(%{user: author, content: "older public post"})
      newer = post_fixture(%{user: author, content: "newer public post"})

      conn =
        build_conn(:get, "/api/v1/timelines/public?limit=1")
        |> assign(:current_user, viewer)
        |> TimelineController.public(%{"limit" => "1", "max_id" => to_string(newer.id)})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(older.id)
      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/timelines/public?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/timelines/public?limit=1&since_id=#{older.id}"
    end
  end
end
