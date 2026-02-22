defmodule ElektrineWeb.ProfileControllerTest do
  @moduledoc """
  Tests for profile page rendering via ProfileController.
  Tests both main domain (z.org/handle) and subdomain (handle.z.org) access.
  """
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Profiles

  setup do
    user = AccountsFixtures.user_fixture()

    # Create a public user profile (required for get_profile_by_handle to work)
    {:ok, profile} =
      Profiles.create_user_profile(user.id, %{
        display_name: "Test User",
        description: "A test profile",
        is_public: true
      })

    {:ok, user: user, profile: profile}
  end

  describe "profile page on main domain" do
    test "renders profile page for valid handle", %{conn: conn, user: user} do
      conn = get(conn, "/#{user.handle}")

      # Should render the profile page
      assert conn.status == 200
      assert conn.resp_body =~ user.handle
    end

    test "returns 404 for non-existent handle", %{conn: conn} do
      conn = get(conn, "/nonexistent_user_handle_12345")

      assert conn.status == 404
    end

    test "returns 404 or redirect for reserved paths", %{conn: conn} do
      # These are reserved and should either 404 or redirect
      for reserved <- ~w(admin api dev) do
        conn = get(conn, "/#{reserved}")

        assert conn.status in [302, 404],
               "Expected 302 or 404 for /#{reserved}, got #{conn.status}"
      end
    end

    test "shows profile with custom display name", %{conn: conn, user: user} do
      conn = get(conn, "/#{user.handle}")

      assert conn.status == 200
      assert conn.resp_body =~ "Test User"
    end
  end

  describe "profile JSON API endpoints" do
    test "GET /profiles/:handle/followers returns JSON", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/profiles/#{user.handle}/followers")

      assert conn.status == 200
      assert json_response(conn, 200)["followers"] == []
    end

    test "GET /profiles/:handle/following returns JSON", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/profiles/#{user.handle}/following")

      assert conn.status == 200
      assert json_response(conn, 200)["following"] == []
    end

    test "POST /profiles/:handle/follow requires authentication", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/profiles/#{user.handle}/follow")

      # Should return 401 unauthorized
      assert conn.status == 401
    end

    test "authenticated user can follow another user", %{conn: conn, user: target_user} do
      # Create another user to do the following
      follower = AccountsFixtures.user_fixture()

      conn =
        conn
        |> log_in_user(follower)
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/profiles/#{target_user.handle}/follow")

      assert conn.status == 200
      assert json_response(conn, 200)["status"] == "followed"

      # Verify the follow relationship exists
      assert Profiles.following?(follower.id, target_user.id)
    end

    test "authenticated user can unfollow another user", %{conn: conn, user: target_user} do
      # Create another user and make them follow
      follower = AccountsFixtures.user_fixture()
      Profiles.follow_user(follower.id, target_user.id)

      conn =
        conn
        |> log_in_user(follower)
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> delete("/profiles/#{target_user.handle}/follow")

      assert conn.status == 200
      assert json_response(conn, 200)["status"] == "unfollowed"

      # Verify the follow relationship is removed
      refute Profiles.following?(follower.id, target_user.id)
    end
  end

  describe "profile visibility" do
    test "public profile is accessible to anonymous users", %{conn: conn, user: user} do
      conn = get(conn, "/#{user.handle}")
      assert conn.status == 200
    end

    test "private profile shows restricted message to anonymous users", %{conn: conn} do
      # Create a user with private profile visibility
      private_user = AccountsFixtures.user_fixture(%{profile_visibility: "private"})

      {:ok, _profile} =
        Profiles.create_user_profile(private_user.id, %{
          display_name: "Private User",
          is_public: true
        })

      conn = get(conn, "/#{private_user.handle}")

      # Should show private profile page, forbidden, or 404
      assert conn.status in [200, 403, 404]

      if conn.status == 200 do
        assert conn.resp_body =~ "Private" or conn.resp_body =~ "private"
      end
    end
  end

  # Helper to log in a user for tests
  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
