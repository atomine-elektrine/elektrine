defmodule ElektrineWeb.API.TagControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social
  alias Elektrine.Social.HashtagExtractor
  alias Elektrine.Social.HashtagFollows
  alias ElektrineWeb.API.TagController

  describe "follow/2 and unfollow/2" do
    test "toggles tag follow state for the current user", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> TagController.follow(%{"id" => "Kairo"})

      assert %{
               "name" => "kairo",
               "following" => true,
               "url" => url,
               "history" => [%{"uses" => 0, "accounts" => 1}]
             } = json_response(conn, 200)

      assert String.ends_with?(url, "/tags/kairo")
      assert HashtagFollows.following?(user.id, "kairo")

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> TagController.unfollow(%{"id" => "kairo"})

      assert %{"name" => "kairo", "following" => false} = json_response(conn, 200)
      refute HashtagFollows.following?(user.id, "kairo")
    end

    test "rejects invalid tag names", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> TagController.follow(%{"id" => "bad tag"})

      assert %{"error" => "invalid tag"} = json_response(conn, 422)
    end
  end

  describe "index_followed/2" do
    test "lists only the current user's followed tags", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      assert {:ok, _} = HashtagFollows.follow_hashtag(user.id, "kairo")
      assert {:ok, _} = HashtagFollows.follow_hashtag(other_user.id, "other")

      conn =
        conn
        |> assign(:current_user, user)
        |> TagController.index_followed(%{})

      assert [%{"name" => "kairo", "following" => true}] = json_response(conn, 200)
    end
  end

  describe "show/2" do
    test "shows tag metadata and current follow state", %{conn: conn} do
      user = user_fixture()
      _tag = Social.get_or_create_hashtag("kairo")

      conn =
        conn
        |> assign(:current_user, user)
        |> TagController.show(%{"id" => "kairo"})

      assert %{"name" => "kairo", "following" => false, "history" => [_]} =
               json_response(conn, 200)
    end

    test "returns 404 for missing tags", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> TagController.show(%{"id" => "missing"})

      assert %{"error" => "tag not found"} = json_response(conn, 404)
    end
  end

  describe "timeline/2" do
    test "lists public posts for a tag", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture(%{username: "tagauthor"})

      matching = post_fixture(%{user: author, content: "shipping #kairo", visibility: "public"})
      HashtagExtractor.process_hashtags_for_message(matching.id, ["kairo"])

      unrelated = post_fixture(%{user: author, content: "plain", visibility: "public"})
      HashtagExtractor.process_hashtags_for_message(unrelated.id, ["other"])

      private = post_fixture(%{user: author, content: "private #kairo", visibility: "private"})
      HashtagExtractor.process_hashtags_for_message(private.id, ["kairo"])

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TagController.timeline(%{"tag" => "kairo"})

      assert [%{"id" => id, "content" => "shipping #kairo", "account" => %{"remote" => false}}] =
               json_response(conn, 200)

      assert id == to_string(matching.id)
      refute id == to_string(unrelated.id)
      refute id == to_string(private.id)
    end

    test "supports max_id pagination" do
      viewer = user_fixture()
      author = user_fixture()

      older = post_fixture(%{user: author, content: "older #kairo"})
      HashtagExtractor.process_hashtags_for_message(older.id, ["kairo"])

      newer = post_fixture(%{user: author, content: "newer #kairo"})
      HashtagExtractor.process_hashtags_for_message(newer.id, ["kairo"])

      conn =
        build_conn(:get, "/api/v1/timelines/tag/kairo?limit=1")
        |> assign(:current_user, viewer)
        |> TagController.timeline(%{
          "tag" => "kairo",
          "limit" => "1",
          "max_id" => to_string(newer.id)
        })

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(older.id)
      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/timelines/tag/kairo?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/timelines/tag/kairo?limit=1&since_id=#{older.id}"
    end

    test "supports any, all, and none tag filters", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()

      any_match = post_fixture(%{user: author, content: "any match #kairo #phoenix"})
      HashtagExtractor.process_hashtags_for_message(any_match.id, ["kairo", "phoenix"])

      all_match = post_fixture(%{user: author, content: "all match #kairo #elixir"})
      HashtagExtractor.process_hashtags_for_message(all_match.id, ["kairo", "elixir"])

      rejected = post_fixture(%{user: author, content: "rejected #kairo #spam"})
      HashtagExtractor.process_hashtags_for_message(rejected.id, ["kairo", "spam"])

      conn =
        conn
        |> assign(:current_user, viewer)
        |> TagController.timeline(%{
          "tag" => "kairo",
          "any" => ["phoenix"],
          "all" => ["elixir"],
          "none" => ["spam"]
        })

      assert [%{"id" => id, "content" => "all match #kairo #elixir"}] = json_response(conn, 200)
      assert id == to_string(all_match.id)
      refute id == to_string(any_match.id)
      refute id == to_string(rejected.id)
    end
  end
end
