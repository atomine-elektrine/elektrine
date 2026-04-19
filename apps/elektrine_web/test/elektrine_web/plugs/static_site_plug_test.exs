defmodule ElektrineWeb.Plugs.StaticSitePlugTest do
  # Must be async: false for the plug to see test database data
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Domains
   alias Elektrine.{Accounts, Profiles, StaticSites}
  alias Elektrine.Profiles.CustomDomain
  alias Elektrine.Repo
  alias ElektrineWeb.Plugs.{ProfileCustomDomain, RuntimeSession}

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
    test "redirects app-host profile roots to username subdomains", %{user: user} do
      host = Domains.primary_profile_domain()

      conn =
        Plug.Test.conn(:get, "/#{user.handle}")
        |> Map.put(:host, host)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://#{user.handle}.#{host}/"]
    end

    test "serves index.html on username subdomains", %{user: user, html_content: html_content} do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 200
      assert conn.resp_body == html_content
      assert {"content-type", "text/html; charset=utf-8"} in conn.resp_headers
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self' https: http: 'unsafe-inline'"
      refute csp =~ "unsafe-eval"
      assert csp =~ "object-src 'none'"
      assert csp =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "serves svg assets with restrictive svg csp", %{user: user} do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>)

      {:ok, _} = StaticSites.upload_file(user, "icon.svg", svg, "image/svg+xml")

      conn =
        Plug.Test.conn(:get, "/icon.svg")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 200
      assert conn.resp_body == svg
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox"
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "redirects app-host static assets to username subdomains", %{user: user} do
      host = Domains.primary_profile_domain()

      conn =
        Plug.Test.conn(:get, "/#{user.handle}/style.css")
        |> Map.put(:host, host)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://#{user.handle}.#{host}/style.css"]
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

    test "serves static sites on verified custom root domains", %{
      conn: conn,
      user: user,
      html_content: html_content
    } do
      unique = System.unique_integer([:positive])
      custom_domain = "static#{unique}.brand.test"

      Repo.insert!(%CustomDomain{
        domain: custom_domain,
        verification_token: "verify-#{unique}",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn =
        conn
        |> Map.put(:host, custom_domain)
        |> get("/")

      assert conn.status == 200
      assert conn.resp_body == html_content
    end

    test "serves custom-domain static sites before the session is fetched", %{
      user: user,
      html_content: html_content
    } do
      unique = System.unique_integer([:positive])
      custom_domain = "runtime#{unique}.brand.test"

      Repo.insert!(%CustomDomain{
        domain: custom_domain,
        verification_token: "verify-#{unique}",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:host, custom_domain)
        |> Map.put(:secret_key_base, String.duplicate("a", 64))
        |> RuntimeSession.call([])
        |> ProfileCustomDomain.call([])

      assert conn.status == 200
      assert conn.resp_body == html_content
    end

    test "serves nested static assets on verified custom root domains", %{
      conn: conn,
      user: user
    } do
      unique = System.unique_integer([:positive])
      custom_domain = "staticasset#{unique}.brand.test"

      {:ok, _} = StaticSites.upload_file(user, "css/site.css", ".profile{color:red;}", "text/css")

      Repo.insert!(%CustomDomain{
        domain: custom_domain,
        verification_token: "verify-#{unique}",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn =
        conn
        |> Map.put(:host, custom_domain)
        |> get("/css/site.css")

      assert conn.status == 200
      assert conn.resp_body == ".profile{color:red;}"
    end

    test "serves root-level static assets on verified custom root domains", %{user: user} do
      robots = "User-agent: *\nAllow: /\n"

      {:ok, _} = StaticSites.upload_file(user, "robots.txt", robots, "text/plain")

      conn =
        Plug.Test.conn(:get, "/robots.txt")
        |> Plug.Conn.assign(:profile_custom_domain, "brand.test")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      assert conn.status == 200
      assert conn.resp_body == robots
      assert {"content-type", "text/plain; charset=utf-8"} in conn.resp_headers
    end

    test "does not intercept app endpoints on subdomains", %{user: user} do
      conn =
        Plug.Test.conn(:get, "/profiles/#{user.handle}/followers")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      refute conn.halted
      assert conn.status == nil
    end

    test "falls through for unknown app-host asset paths", %{user: user} do
      conn =
        Plug.Test.conn(:get, "/#{user.handle}/nonexistent.js")
        |> Map.put(:host, "example.com")
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      refute conn.halted
      assert conn.status == nil
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

    test "does not serve built-in subdomain static pages after dns handoff", %{user: user} do
      {:ok, _user} = Accounts.update_user(user, %{built_in_subdomain_mode: "external_dns"})

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:subdomain_handle, user.handle)
        |> ElektrineWeb.Plugs.StaticSitePlug.call([])

      refute conn.halted
      assert conn.status == nil
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
