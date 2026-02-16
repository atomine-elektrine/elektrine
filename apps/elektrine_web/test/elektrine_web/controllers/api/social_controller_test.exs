defmodule ElektrineWeb.API.SocialControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.SocialFixtures
  alias ElektrineWeb.Plugs.APIAuth

  setup do
    user = AccountsFixtures.user_fixture()
    {:ok, token} = APIAuth.generate_token(user.id)
    %{user: user, token: token}
  end

  defp auth_conn(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "GET /api/social/timeline" do
    test "returns timeline posts", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/timeline")

      response = json_response(conn, 200)
      assert is_list(response["posts"]) or is_list(response)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/social/timeline")
      assert json_response(conn, 401)
    end

    test "supports cursor pagination", %{conn: conn, user: user, token: token} do
      older = SocialFixtures.post_fixture(%{user: user, content: "older timeline post"})
      newer = SocialFixtures.post_fixture(%{user: user, content: "newer timeline post"})

      first_page =
        conn
        |> auth_conn(token)
        |> get("/api/social/timeline", %{limit: 1})
        |> json_response(200)

      assert [%{"id" => first_id}] = first_page["posts"]
      assert first_id == newer.id
      assert first_page["next_cursor"] == Integer.to_string(newer.id)

      second_page =
        build_conn()
        |> auth_conn(token)
        |> get("/api/social/timeline", %{limit: 1, cursor: first_page["next_cursor"]})
        |> json_response(200)

      assert [%{"id" => second_id}] = second_page["posts"]
      assert second_id == older.id
      assert second_id < first_id
    end

    test "supports min_id pagination with ascending order", %{
      conn: conn,
      user: user,
      token: token
    } do
      oldest = SocialFixtures.post_fixture(%{user: user, content: "oldest timeline post"})
      middle = SocialFixtures.post_fixture(%{user: user, content: "middle timeline post"})
      newest = SocialFixtures.post_fixture(%{user: user, content: "newest timeline post"})

      response =
        conn
        |> auth_conn(token)
        |> get("/api/social/timeline", %{min_id: oldest.id, order: "asc", limit: 20})
        |> json_response(200)

      ids = Enum.map(response["posts"], & &1["id"])

      assert ids == Enum.sort(ids)
      assert Enum.all?(ids, &(&1 > oldest.id))
      assert middle.id in ids
      assert newest.id in ids
    end
  end

  describe "GET /api/social/timeline/public" do
    test "returns public timeline", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/timeline/public")

      response = json_response(conn, 200)
      assert is_list(response["posts"]) or is_list(response)
    end
  end

  describe "POST /api/social/posts" do
    test "creates a new post", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/social/posts", %{content: "Hello from API test!"})

      response = json_response(conn, 201)
      assert response["post"]["content"] =~ "Hello from API test!"
    end

    test "returns error for empty content", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/social/posts", %{content: ""})

      # Should return 400 or 422 for validation error
      assert conn.status in [400, 422]
    end
  end

  describe "GET /api/social/posts/:id" do
    test "returns post details", %{conn: conn, user: user, token: token} do
      post = SocialFixtures.post_fixture(%{user: user, content: "Test post"})

      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/posts/#{post.id}")

      response = json_response(conn, 200)
      assert response["post"]["content"] =~ "Test post"
    end

    test "returns 404 for non-existent post", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/posts/999999999")

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/social/posts/:id" do
    test "deletes own post", %{conn: conn, user: user, token: token} do
      post = SocialFixtures.post_fixture(%{user: user, content: "To delete"})

      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/social/posts/#{post.id}")

      assert conn.status in [200, 204]
    end

    test "cannot delete another user's post", %{conn: conn, token: token} do
      other_user = AccountsFixtures.user_fixture()
      post = SocialFixtures.post_fixture(%{user: other_user, content: "Protected"})

      conn =
        conn
        |> auth_conn(token)
        |> delete("/api/social/posts/#{post.id}")

      assert conn.status in [403, 404]
    end
  end

  describe "POST /api/social/posts/:id/like" do
    test "likes a post", %{conn: conn, user: user, token: token} do
      other_user = AccountsFixtures.user_fixture()
      post = SocialFixtures.post_fixture(%{user: other_user, content: "Likeable"})

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/social/posts/#{post.id}/like")

      assert conn.status in [200, 201]
    end
  end

  describe "DELETE /api/social/posts/:id/like" do
    test "unlikes a post", %{conn: conn, user: user, token: token} do
      other_user = AccountsFixtures.user_fixture()
      post = SocialFixtures.post_fixture(%{user: other_user, content: "Unlikeable"})

      # First like it
      conn
      |> auth_conn(token)
      |> post("/api/social/posts/#{post.id}/like")

      # Then unlike
      conn2 =
        build_conn()
        |> auth_conn(token)
        |> delete("/api/social/posts/#{post.id}/like")

      assert conn2.status in [200, 204]
    end
  end

  describe "GET /api/social/followers" do
    test "returns followers list", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/followers")

      response = json_response(conn, 200)
      assert is_list(response["users"])
    end
  end

  describe "GET /api/social/following" do
    test "returns following list", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/following")

      response = json_response(conn, 200)
      assert is_list(response["users"])
    end
  end

  describe "POST /api/social/users/:user_id/follow" do
    test "follows a user", %{conn: conn, token: token} do
      other_user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> auth_conn(token)
        |> post("/api/social/users/#{other_user.id}/follow")

      assert conn.status in [200, 201]
    end

    test "cannot follow self", %{conn: conn, user: user, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post("/api/social/users/#{user.id}/follow")

      # Should error when trying to follow self
      assert conn.status in [400, 422]
    end
  end

  describe "DELETE /api/social/users/:user_id/follow" do
    test "unfollows a user", %{conn: conn, token: token} do
      other_user = AccountsFixtures.user_fixture()

      # First follow
      conn
      |> auth_conn(token)
      |> post("/api/social/users/#{other_user.id}/follow")

      # Then unfollow
      conn2 =
        build_conn()
        |> auth_conn(token)
        |> delete("/api/social/users/#{other_user.id}/follow")

      assert conn2.status in [200, 204]
    end
  end

  describe "GET /api/social/users/search" do
    test "searches for users", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> get("/api/social/users/search", %{q: "test"})

      response = json_response(conn, 200)
      assert is_list(response["users"])
    end
  end
end
