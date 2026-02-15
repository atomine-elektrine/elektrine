defmodule ElektrineWeb.Plugs.ProfileSubdomainTest do
  @moduledoc """
  Tests for the ProfileSubdomain plug that handles profile subdomains.

  Subdomains should:
  - Only serve the profile page at root (/)
  - Redirect all other paths to the main domain
  - Allow /profiles/* API calls for follow actions
  - Allow asset-like paths (e.g., *.jpg, *.css, *.js) through so static sites can serve assets on subdomains
  """
  use ElektrineWeb.ConnCase, async: true

  alias ElektrineWeb.Plugs.ProfileSubdomain

  describe "subdomain extraction" do
    test "extracts handle from valid subdomain" do
      conn =
        build_conn_with_host("maxfield.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.assigns[:subdomain_handle] == "maxfield"
    end

    test "extracts handle from valid elektrine.com subdomain" do
      conn =
        build_conn_with_host("maxfield.elektrine.com", "/")
        |> ProfileSubdomain.call([])

      assert conn.assigns[:subdomain_handle] == "maxfield"
    end

    test "rewrites root path to /subdomain/:handle" do
      conn =
        build_conn_with_host("maxfield.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.request_path == "/subdomain/maxfield"
      assert conn.path_info == ["subdomain", "maxfield"]
    end

    test "does not modify main domain requests" do
      conn =
        build_conn_with_host("z.org", "/timeline")
        |> ProfileSubdomain.call([])

      refute conn.assigns[:subdomain_handle]
      assert conn.request_path == "/timeline"
    end

    test "does not modify elektrine.com main domain requests" do
      conn =
        build_conn_with_host("elektrine.com", "/timeline")
        |> ProfileSubdomain.call([])

      refute conn.assigns[:subdomain_handle]
      assert conn.request_path == "/timeline"
    end

    test "does not modify localhost requests" do
      conn =
        build_conn_with_host("localhost", "/some/path")
        |> ProfileSubdomain.call([])

      refute conn.assigns[:subdomain_handle]
      assert conn.request_path == "/some/path"
    end
  end

  describe "reserved subdomains" do
    test "redirects www subdomain to main domain" do
      conn =
        build_conn_with_host("www.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://z.org/"]
    end

    test "redirects admin subdomain to main domain" do
      conn =
        build_conn_with_host("admin.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://z.org/"]
    end

    test "redirects api subdomain to main domain" do
      conn =
        build_conn_with_host("api.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://z.org/"]
    end

    test "redirects mail subdomain to main domain" do
      conn =
        build_conn_with_host("mail.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
    end

    test "redirects www.elektrine.com subdomain to main domain" do
      conn =
        build_conn_with_host("www.elektrine.com", "/")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://elektrine.com/"]
    end
  end

  describe "path handling on subdomains" do
    test "redirects non-root paths to main domain" do
      conn =
        build_conn_with_host("maxfield.z.org", "/timeline")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://z.org/timeline"]
    end

    test "redirects nested paths to main domain" do
      conn =
        build_conn_with_host("maxfield.z.org", "/timeline/post/123")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://z.org/timeline/post/123"]
    end

    test "redirects /handle to root on subdomain" do
      conn =
        build_conn_with_host("maxfield.z.org", "/maxfield")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/"]
    end

    test "does not redirect asset-like paths (allows static-site assets on subdomains)" do
      conn =
        build_conn_with_host("maxfield.z.org", "/1.jpg")
        |> ProfileSubdomain.call([])

      refute conn.halted
      assert conn.assigns[:subdomain_handle] == "maxfield"
      assert conn.request_path == "/1.jpg"
    end

    test "redirects non-root paths to elektrine.com main domain" do
      conn =
        build_conn_with_host("maxfield.elektrine.com", "/timeline")
        |> ProfileSubdomain.call([])

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://elektrine.com/timeline"]
    end

    test "does not redirect asset-like paths on elektrine.com subdomains" do
      conn =
        build_conn_with_host("maxfield.elektrine.com", "/1.jpg")
        |> ProfileSubdomain.call([])

      refute conn.halted
      assert conn.assigns[:subdomain_handle] == "maxfield"
      assert conn.request_path == "/1.jpg"
    end

    test "bypasses /profiles/* API paths (for browser_api pipeline)" do
      conn =
        build_conn_with_host("maxfield.z.org", "/profiles/maxfield/followers")
        |> ProfileSubdomain.call([])

      # /profiles/* paths are bypassed entirely so they can be handled by browser_api pipeline
      refute conn.halted
      # subdomain_handle is NOT set because bypass happens before extraction
      assert conn.request_path == "/profiles/maxfield/followers"
    end

    test "bypasses /profiles/:handle/follow API path" do
      conn =
        build_conn_with_host("maxfield.z.org", "/profiles/maxfield/follow")
        |> ProfileSubdomain.call([])

      # /profiles/* paths are bypassed for API calls
      refute conn.halted
    end
  end

  describe "bypass paths" do
    test "bypasses /assets paths" do
      conn =
        build_conn_with_host("maxfield.z.org", "/assets/app.js")
        |> ProfileSubdomain.call([])

      refute conn.halted
      # Assets should pass through without subdomain processing
      refute conn.assigns[:subdomain_handle]
    end

    test "bypasses /uploads paths" do
      conn =
        build_conn_with_host("maxfield.z.org", "/uploads/avatar.png")
        |> ProfileSubdomain.call([])

      refute conn.halted
    end

    test "bypasses /live paths for LiveView" do
      conn =
        build_conn_with_host("maxfield.z.org", "/live/websocket")
        |> ProfileSubdomain.call([])

      refute conn.halted
    end

    test "bypasses favicon.ico" do
      conn =
        build_conn_with_host("maxfield.z.org", "/favicon.ico")
        |> ProfileSubdomain.call([])

      refute conn.halted
    end

    test "bypasses robots.txt" do
      conn =
        build_conn_with_host("maxfield.z.org", "/robots.txt")
        |> ProfileSubdomain.call([])

      refute conn.halted
    end
  end

  describe "invalid subdomains" do
    test "subdomains with extra dots are not matched" do
      conn =
        build_conn_with_host("some.thing.z.org", "/")
        |> ProfileSubdomain.call([])

      # Multi-label subdomains are not treated as profile subdomains.
      refute conn.assigns[:subdomain_handle]
    end

    test "numerical subdomains are allowed" do
      conn =
        build_conn_with_host("user123.z.org", "/")
        |> ProfileSubdomain.call([])

      assert conn.assigns[:subdomain_handle] == "user123"
    end
  end

  describe "forwarded host headers" do
    test "uses x-forwarded-host header when present" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:host, "internal-server")
        |> Plug.Conn.put_req_header("x-forwarded-host", "maxfield.z.org")
        |> ProfileSubdomain.call([])

      assert conn.assigns[:subdomain_handle] == "maxfield"
    end

    test "prioritizes subdomain host over main domain in forwarded headers" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:host, "z.org")
        |> Plug.Conn.put_req_header("x-forwarded-host", "maxfield.z.org, z.org")
        |> ProfileSubdomain.call([])

      assert conn.assigns[:subdomain_handle] == "maxfield"
    end

    test "prioritizes elektrine.com subdomain host over main domain in forwarded headers" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:host, "elektrine.com")
        |> Plug.Conn.put_req_header("x-forwarded-host", "maxfield.elektrine.com, elektrine.com")
        |> ProfileSubdomain.call([])

      assert conn.assigns[:subdomain_handle] == "maxfield"
    end
  end

  # Helper to build a conn with a specific host
  defp build_conn_with_host(host, path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:host, host)
  end
end
