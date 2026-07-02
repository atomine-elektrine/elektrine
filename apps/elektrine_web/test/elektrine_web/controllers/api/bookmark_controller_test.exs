defmodule ElektrineWeb.API.BookmarkControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social
  alias Elektrine.Social.BookmarkFolders
  alias ElektrineWeb.API.BookmarkController

  describe "index/2" do
    test "lists only the current user's bookmarked statuses", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      post = post_fixture(%{content: "saved by current user"})
      other_post = post_fixture(%{content: "saved by someone else"})

      assert {:ok, _} = Social.save_post(user.id, post.id)
      assert {:ok, _} = Social.save_post(other_user.id, other_post.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> BookmarkController.index(%{})

      assert [%{"id" => id, "content" => "saved by current user", "bookmarked" => true}] =
               json_response(conn, 200)

      assert id == to_string(post.id)
    end

    test "supports bookmark folder filtering", %{conn: conn} do
      user = user_fixture()
      {:ok, folder} = BookmarkFolders.create_folder(user.id, %{"name" => "Read later"})

      folder_post = post_fixture(%{content: "folder saved post"})
      other_post = post_fixture(%{content: "other saved post"})

      assert {:ok, _} = Social.save_post(user.id, folder_post.id, folder_id: folder.id)
      assert {:ok, _} = Social.save_post(user.id, other_post.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> BookmarkController.index(%{"bookmark_folder_id" => to_string(folder.id)})

      assert [%{"id" => id, "content" => "folder saved post"}] = json_response(conn, 200)
      assert id == to_string(folder_post.id)
    end

    test "supports search filtering", %{conn: conn} do
      user = user_fixture()
      matching = post_fixture(%{content: "searchable bookmark"})
      other = post_fixture(%{content: "plain bookmark"})

      assert {:ok, _} = Social.save_post(user.id, matching.id)
      assert {:ok, _} = Social.save_post(user.id, other.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> BookmarkController.index(%{"q" => "searchable"})

      assert [%{"id" => id, "content" => "searchable bookmark"}] = json_response(conn, 200)
      assert id == to_string(matching.id)
    end

    test "supports max_id pagination with link headers" do
      user = user_fixture()
      older = post_fixture(%{content: "older bookmark"})
      newer = post_fixture(%{content: "newer bookmark"})

      assert {:ok, _} = Social.save_post(user.id, older.id)
      assert {:ok, _} = Social.save_post(user.id, newer.id)

      conn =
        build_conn(:get, "/api/v1/bookmarks?limit=1")
        |> assign(:current_user, user)
        |> BookmarkController.index(%{"limit" => "1", "max_id" => to_string(newer.id)})

      assert [%{"id" => id, "content" => "older bookmark"}] = json_response(conn, 200)
      assert id == to_string(older.id)

      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/bookmarks?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/bookmarks?limit=1&since_id=#{older.id}"
    end
  end
end
