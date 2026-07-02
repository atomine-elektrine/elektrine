defmodule ElektrineWeb.API.StatusPinControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social
  alias ElektrineWeb.API.StatusPinController

  describe "pin/2" do
    test "pins the current user's status", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusPinController.pin(%{"id" => to_string(post.id)})

      assert %{
               "id" => id,
               "content" => _content,
               "pinned" => true,
               "visibility" => "public"
             } = json_response(conn, 200)

      assert id == to_string(post.id)
    end

    test "rejects another user's status", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      post = post_fixture(%{user: other_user, visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusPinController.pin(%{"id" => to_string(post.id)})

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns not found for a missing status", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusPinController.pin(%{"id" => "-1"})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  describe "unpin/2" do
    test "unpins the current user's status", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      assert {:ok, _pinned} = Social.pin_timeline_post(user.id, post.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusPinController.unpin(%{"id" => to_string(post.id)})

      assert %{"id" => id, "pinned" => false} = json_response(conn, 200)
      assert id == to_string(post.id)
    end
  end
end
