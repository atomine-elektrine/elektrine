defmodule ElektrineWeb.API.FavouriteControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social
  alias ElektrineWeb.API.FavouriteController

  describe "index/2" do
    test "lists only the current user's favourited statuses", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      post = post_fixture(%{content: "liked by current user"})
      other_post = post_fixture(%{content: "liked by someone else"})

      assert {:ok, _} = Social.like_post(user.id, post.id)
      assert {:ok, _} = Social.like_post(other_user.id, other_post.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> FavouriteController.index(%{})

      assert [%{"id" => id, "content" => "liked by current user", "favourited" => true}] =
               json_response(conn, 200)

      assert id == to_string(post.id)
    end

    test "supports search filtering", %{conn: conn} do
      user = user_fixture()
      matching = post_fixture(%{content: "searchable favourite"})
      other = post_fixture(%{content: "plain favourite"})

      assert {:ok, _} = Social.like_post(user.id, matching.id)
      assert {:ok, _} = Social.like_post(user.id, other.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> FavouriteController.index(%{"q" => "searchable"})

      assert [%{"id" => id, "content" => "searchable favourite"}] = json_response(conn, 200)
      assert id == to_string(matching.id)
    end

    test "supports max_id pagination with link headers" do
      user = user_fixture()
      older = post_fixture(%{content: "older favourite"})
      newer = post_fixture(%{content: "newer favourite"})

      assert {:ok, _} = Social.like_post(user.id, older.id)
      assert {:ok, _} = Social.like_post(user.id, newer.id)

      conn =
        build_conn(:get, "/api/v1/favourites?limit=1")
        |> assign(:current_user, user)
        |> FavouriteController.index(%{"limit" => "1", "max_id" => to_string(newer.id)})

      assert [%{"id" => id, "content" => "older favourite"}] = json_response(conn, 200)
      assert id == to_string(older.id)

      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/favourites?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/favourites?limit=1&since_id=#{older.id}"
    end

    test "excludes favourited statuses that are no longer visible", %{conn: conn} do
      viewer = user_fixture()
      owner = user_fixture()
      hidden = post_fixture(%{user: owner, content: "hidden favourite", visibility: "private"})

      assert {:ok, _} = Social.like_post(owner.id, hidden.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> FavouriteController.index(%{})

      assert [] = json_response(conn, 200)
    end
  end
end
