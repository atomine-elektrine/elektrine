defmodule ElektrineWeb.API.AccountRelationshipFollowControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Profiles
  alias ElektrineWeb.API.AccountRelationshipController

  describe "followers/2" do
    test "lists an account's followers", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      follower = user_fixture(%{username: "followerone"})

      assert {:ok, _follow} = Profiles.follow_user(follower.id, target.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.followers(%{"id" => to_string(target.id)})

      assert [%{"id" => id, "username" => "followerone"}] = json_response(conn, 200)
      assert id == to_string(follower.id)
    end

    test "embeds follower relationships when requested", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      follower = user_fixture(%{username: "followerembedded"})

      assert {:ok, _follow} = Profiles.follow_user(follower.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(viewer.id, follower.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.followers(%{
          "id" => to_string(target.id),
          "with_relationships" => "true"
        })

      assert [
               %{
                 "id" => id,
                 "pleroma" => %{"relationship" => %{"following" => true}}
               }
             ] = json_response(conn, 200)

      assert id == to_string(follower.id)
    end

    test "supports max_id pagination with link headers" do
      viewer = user_fixture()
      target = user_fixture()
      older = user_fixture()
      newer = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(older.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(newer.id, target.id)

      conn =
        build_conn(:get, "/api/v1/accounts/#{target.id}/followers?limit=1")
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.followers(%{
          "id" => to_string(target.id),
          "limit" => "1",
          "max_id" => to_string(newer.id)
        })

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(older.id)

      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/accounts/#{target.id}/followers?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/accounts/#{target.id}/followers?limit=1&since_id=#{older.id}"
    end
  end

  describe "following/2" do
    test "lists accounts followed by an account", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      followed = user_fixture(%{username: "followedone"})

      assert {:ok, _follow} = Profiles.follow_user(target.id, followed.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.following(%{"id" => to_string(target.id)})

      assert [%{"id" => id, "username" => "followedone"}] = json_response(conn, 200)
      assert id == to_string(followed.id)
    end

    test "embeds following relationships when requested", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      followed = user_fixture(%{username: "followingembedded"})

      assert {:ok, _follow} = Profiles.follow_user(target.id, followed.id)
      assert {:ok, _follow} = Profiles.follow_user(viewer.id, followed.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.following(%{
          "id" => to_string(target.id),
          "with_relationships" => "true"
        })

      assert [
               %{
                 "id" => id,
                 "pleroma" => %{"relationship" => %{"following" => true}}
               }
             ] = json_response(conn, 200)

      assert id == to_string(followed.id)
    end

    test "returns 404 for missing accounts", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.following(%{"id" => "-1"})

      assert %{"error" => "account not found"} = json_response(conn, 404)
    end
  end
end
