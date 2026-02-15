defmodule ElektrineWeb.CommunityPostTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Accounts
  alias Elektrine.Messaging

  setup do
    # Create a test user
    {:ok, user} =
      Accounts.create_user(%{
        username: "communitypostuser#{System.unique_integer([:positive])}",
        password: "Test123456!",
        password_confirmation: "Test123456!"
      })

    # Create a test community
    {:ok, community} =
      Messaging.create_group_conversation(
        user.id,
        %{
          name: "TestCommunity#{System.unique_integer([:positive])}",
          description: "A test community for post creation tests",
          type: "community",
          community_category: "tech",
          is_public: true,
          allow_public_posts: true,
          discussion_style: "forum"
        },
        []
      )

    %{user: user, community: community}
  end

  # Helper to log in a user for LiveView tests
  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  describe "post creation character counter" do
    test "displays character count for text post content", %{
      conn: conn,
      user: user,
      community: community
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Initial state should show 0 / 10,000
      html = render(view)
      assert html =~ "0 / 10,000"
    end

    test "updates character count as user types in text post", %{
      conn: conn,
      user: user,
      community: community
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Type some content using the form's phx-change handler
      test_content = "This is a test post content"

      view
      |> form("#new-post-form", %{content: test_content})
      |> render_change()

      # Should show updated character count
      html = render(view)
      assert html =~ "#{String.length(test_content)} / 10,000"
    end

    test "shows warning color when approaching limit", %{
      conn: conn,
      user: user,
      community: community
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Type content over 8000 chars (warning threshold) using the form's phx-change handler
      long_content = String.duplicate("a", 8500)

      view
      |> form("#new-post-form", %{content: long_content})
      |> render_change()

      html = render(view)
      # Should have warning color class
      assert html =~ "text-warning"
      assert html =~ "8500 / 10,000"
    end

    test "shows error color when near limit", %{conn: conn, user: user, community: community} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Type content over 9500 chars (error threshold) using the form's phx-change handler
      very_long_content = String.duplicate("a", 9600)

      view
      |> form("#new-post-form", %{content: very_long_content})
      |> render_change()

      html = render(view)
      # Should have error color class
      assert html =~ "text-error"
      assert html =~ "9600 / 10,000"
    end

    test "resets character count when toggling post form", %{
      conn: conn,
      user: user,
      community: community
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form and add content using the form's phx-change handler
      view |> element("button", "New Post") |> render_click()

      view
      |> form("#new-post-form", %{content: "Some content"})
      |> render_change()

      # Close and reopen the form
      view |> element("button", "Cancel") |> render_click()
      view |> element("button", "New Post") |> render_click()

      # Should be reset to 0
      html = render(view)
      assert html =~ "0 / 10,000"
    end

    test "resets character count when changing post type", %{
      conn: conn,
      user: user,
      community: community
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form and add content using the form's phx-change handler
      view |> element("button", "New Post") |> render_click()

      view
      |> form("#new-post-form", %{content: "Some content"})
      |> render_change()

      # Switch to link post type
      view |> element("button", "Link") |> render_click()

      # Should be reset
      html = render(view)
      # Link posts have 5000 char limit
      assert html =~ "0 / 5,000"
    end

    test "link post has 5000 character limit", %{conn: conn, user: user, community: community} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form and switch to link
      view |> element("button", "New Post") |> render_click()
      view |> element("button", "Link") |> render_click()

      html = render(view)
      assert html =~ "0 / 5,000"
    end

    test "image post has 2000 character limit for caption", %{
      conn: conn,
      user: user,
      community: community
    } do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form and switch to image
      view |> element("button", "New Post") |> render_click()
      view |> element("button", "Media") |> render_click()

      html = render(view)
      assert html =~ "0 / 2,000"
    end
  end

  describe "post creation" do
    test "can create a text post with valid content", %{
      conn: conn,
      user: user,
      community: community
    } do
      # Allow async tasks to access the database sandbox
      Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, {:shared, self()})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Fill in the form using the specific phx-submit selector
      html =
        view
        |> form("form[phx-submit=create_discussion_post]", %{
          title: "Test Discussion Title",
          content: "This is the content of my test discussion post."
        })
        |> render_submit()

      # Should show success flash message and close the form
      assert html =~ "Post published in this community." ||
               html =~ "Post submitted. A moderator will review it shortly." ||
               html =~ "Post is pending moderator approval"

      # Form should be closed (New Post button visible again for creating another)
      refute html =~ "phx-submit=\"create_discussion_post\""
    end

    test "requires title for text post", %{conn: conn, user: user, community: community} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Try to submit without title
      html =
        view
        |> form("form[phx-submit=create_discussion_post]", %{
          title: "",
          content: "Some content"
        })
        |> render_submit()

      # Should show error message
      assert html =~ "Title is required"
    end

    test "requires content for text post", %{conn: conn, user: user, community: community} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/communities/#{community.name}")

      # Toggle new post form
      view |> element("button", "New Post") |> render_click()

      # Try to submit without content
      html =
        view
        |> form("form[phx-submit=create_discussion_post]", %{
          title: "Valid Title",
          content: ""
        })
        |> render_submit()

      # Should show error message
      assert html =~ "Content cannot be empty"
    end
  end
end
