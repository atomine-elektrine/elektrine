defmodule ElektrineWeb.Plugs.DAVAuthTest do
  use Elektrine.DataCase
  import Plug.Test
  import Plug.Conn

  alias ElektrineWeb.Plugs.DAVAuth
  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication

  # Helper to create a test user
  defp create_test_user(attrs \\ %{}) do
    default_attrs = %{
      username: "davuser#{System.unique_integer([:positive])}",
      password: "testpassword123",
      password_confirmation: "testpassword123"
    }

    {:ok, user} = Accounts.create_user(Map.merge(default_attrs, attrs))
    user
  end

  # Helper to create app password for user
  defp create_app_password(user) do
    {:ok, app_password} = Authentication.create_app_password(user.id, %{name: "Test App"})
    app_password.token
  end

  # Helper to encode Basic auth header
  defp basic_auth_header(username, password) do
    encoded = Base.encode64("#{username}:#{password}")
    "Basic #{encoded}"
  end

  describe "call/2" do
    test "returns 401 when no authorization header" do
      conn =
        conn(:get, "/")
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "returns 401 when authorization header is invalid format" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Invalid format")
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
    end

    test "returns 401 when Basic auth has invalid base64" do
      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic not-valid-base64!!!")
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
    end

    test "returns 401 when credentials format is wrong" do
      encoded = Base.encode64("no-colon-separator")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", "Basic #{encoded}")
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
    end

    test "returns 401 when user does not exist" do
      auth = basic_auth_header("nonexistent", "password")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
    end

    test "authenticates with valid app password" do
      user = create_test_user()
      token = create_app_password(user)
      auth = basic_auth_header(user.username, token)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end

    test "authenticates with valid password when 2FA is disabled" do
      user =
        create_test_user(%{password: "mypassword123", password_confirmation: "mypassword123"})

      auth = basic_auth_header(user.username, "mypassword123")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end

    test "returns 401 with wrong app password" do
      user = create_test_user()
      _token = create_app_password(user)
      auth = basic_auth_header(user.username, "wrong-token")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
    end

    test "returns 401 with wrong password" do
      user = create_test_user()
      auth = basic_auth_header(user.username, "wrongpassword")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      assert conn.status == 401
      assert conn.halted == true
    end

    test "authenticates with email format username" do
      user = create_test_user()
      token = create_app_password(user)
      email = "#{user.username}@elektrine.com"
      auth = basic_auth_header(email, token)

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end

    test "returns 403 for banned user" do
      user = create_test_user()
      Accounts.ban_user(user, %{banned_reason: "Test ban"})

      auth = basic_auth_header(user.username, "anypassword")

      conn =
        conn(:get, "/")
        |> put_req_header("authorization", auth)
        |> DAVAuth.call([])

      assert conn.status == 403
      assert conn.halted == true
    end

    test "www-authenticate header includes realm" do
      conn =
        conn(:get, "/")
        |> DAVAuth.call([])

      [auth_header] = get_resp_header(conn, "www-authenticate")
      assert String.contains?(auth_header, "Basic realm=")
      assert String.contains?(auth_header, "Elektrine")
    end
  end

  describe "security" do
    test "does not leak user existence on invalid password" do
      # Create a user
      user = create_test_user()

      # Try with existing user, wrong password
      auth1 = basic_auth_header(user.username, "wrongpassword")

      conn1 =
        conn(:get, "/")
        |> put_req_header("authorization", auth1)
        |> DAVAuth.call([])

      # Try with non-existing user
      auth2 = basic_auth_header("nonexistent#{System.unique_integer()}", "anypassword")

      conn2 =
        conn(:get, "/")
        |> put_req_header("authorization", auth2)
        |> DAVAuth.call([])

      # Both should return 401 (not different errors)
      assert conn1.status == 401
      assert conn2.status == 401
    end

    test "timing attack resistance - similar response time for valid and invalid users" do
      # This test verifies that the DAVAuth plug performs a dummy hash
      # when the user is not found, preventing timing attacks that could
      # enumerate valid usernames.

      user = create_test_user()
      auth_valid_user = basic_auth_header(user.username, "wrongpassword")

      auth_invalid_user =
        basic_auth_header("nonexistent#{System.unique_integer()}", "anypassword")

      # Warm up - run once to load modules/cache
      conn(:get, "/") |> put_req_header("authorization", auth_valid_user) |> DAVAuth.call([])
      conn(:get, "/") |> put_req_header("authorization", auth_invalid_user) |> DAVAuth.call([])

      # Run multiple iterations and average the times
      iterations = 5

      times1 =
        for _ <- 1..iterations do
          {time, _} =
            :timer.tc(fn ->
              conn(:get, "/")
              |> put_req_header("authorization", auth_valid_user)
              |> DAVAuth.call([])
            end)

          time
        end

      times2 =
        for _ <- 1..iterations do
          {time, _} =
            :timer.tc(fn ->
              conn(:get, "/")
              |> put_req_header("authorization", auth_invalid_user)
              |> DAVAuth.call([])
            end)

          time
        end

      avg1 = Enum.sum(times1) / iterations
      avg2 = Enum.sum(times2) / iterations

      # Times should be in the same order of magnitude
      ratio = max(avg1, avg2) / max(min(avg1, avg2), 1)

      assert ratio < 50,
             "Response times differ too much: #{avg1}us vs #{avg2}us (ratio: #{ratio})"
    end
  end
end
