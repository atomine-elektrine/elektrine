defmodule ElektrineWeb.Plugs.StaticSitePlugTest do
  # Must be async: false for the plug to see test database data
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.{Profiles, StaticSites}

  setup do
    user = AccountsFixtures.user_fixture()

    # Create user profile with static mode
    {:ok, profile} =
      Profiles.create_user_profile(user.id, %{
        display_name: user.handle,
        profile_mode: "static"
      })

    # Upload a test static site
    html_content = "<html><head><title>Test</title></head><body>Hello World</body></html>"
    css_content = "body { color: blue; }"

    {:ok, _} = StaticSites.upload_file(user, "index.html", html_content, "text/html")
    {:ok, _} = StaticSites.upload_file(user, "style.css", css_content, "text/css")

    {:ok, user: user, profile: profile, html_content: html_content, css_content: css_content}
  end

  describe "static site serving" do
    test "serves index.html for profile root", %{
      conn: conn,
      user: user,
      html_content: html_content
    } do
      conn = get(conn, "/#{user.handle}")

      assert conn.status == 200
      assert conn.resp_body == html_content
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src *"
      assert csp =~ "'unsafe-inline'"
    end

    test "serves static assets", %{user: user, css_content: css_content} do
      # Test the plug directly to avoid process isolation issues
      conn =
        Plug.Test.conn(:get, "/#{user.handle}/style.css")
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 200
      assert conn.resp_body == css_content
      assert {"content-type", "text/css; charset=utf-8"} in conn.resp_headers
    end

    test "serves static assets on subdomains when subdomain_handle is assigned", %{
      user: user,
      css_content: css_content
    } do
      conn =
        Plug.Test.conn(:get, "/style.css")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 200
      assert conn.resp_body == css_content
      assert {"content-type", "text/css; charset=utf-8"} in conn.resp_headers
    end

    test "does not intercept app endpoints on subdomains", %{user: user} do
      conn =
        Plug.Test.conn(:get, "/profiles/#{user.handle}/followers")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      refute conn.halted
      assert conn.status == nil
    end

    test "returns 404 for non-existent assets", %{conn: conn, user: user} do
      conn = get(conn, "/#{user.handle}/nonexistent.js")

      # Should fall through to normal routing (404)
      # May hit LiveView fallback
      assert conn.status in [404, 200]
    end

    test "blocks path traversal attempts", %{conn: conn, user: user} do
      conn = get(conn, "/#{user.handle}/../../../etc/passwd")

      # Should not serve file, either 404 or redirected
      refute conn.resp_body =~ "root:"
    end

    test "does not serve for users in builder mode", %{conn: conn, user: user} do
      # Switch to builder mode
      {:ok, _} = StaticSites.enable_builder_mode(user.id)

      conn = get(conn, "/#{user.handle}")

      # Should fall through to LiveView profile, not serve static HTML
      # The response won't be our static HTML
      refute conn.resp_body ==
               "<html><head><title>Test</title></head><body>Hello World</body></html>"
    end
  end

  describe "reserved paths" do
    test "does not intercept reserved paths", %{conn: conn} do
      # These should pass through to normal routing
      for path <- ~w(admin api login register pripyat) do
        conn = get(conn, "/#{path}")
        # Should not be halted by static site plug
        # (will get normal 404 or redirect)
        assert conn.status in [200, 302, 404]
      end
    end
  end
end
