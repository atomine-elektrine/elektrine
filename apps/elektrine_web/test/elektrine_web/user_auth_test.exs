defmodule ElektrineWeb.UserAuthTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias ElektrineWeb.UserAuth

  setup do
    previous = Application.get_env(:elektrine, :admin_security, [])
    previous_netbird = Application.get_env(:elektrine, :netbird, [])
    previous_trusted_proxy_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs, [])

    Application.put_env(
      :elektrine,
      :admin_security,
      Keyword.merge(previous,
        require_passkey: false,
        access_ttl_seconds: 900,
        elevation_ttl_seconds: 300,
        action_grant_ttl_seconds: 90,
        intent_ttl_seconds: 180,
        replay_ttl_seconds: 600
      )
    )

    Application.put_env(:elektrine, :netbird, enabled: false, allowed_cidrs: [])
    Application.put_env(:elektrine, :trusted_proxy_cidrs, [])

    on_exit(fn ->
      Application.put_env(:elektrine, :admin_security, previous)
      Application.put_env(:elektrine, :netbird, previous_netbird)
      Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_proxy_cidrs)
    end)

    :ok
  end

  describe "require_admin_access/2" do
    test "records forwarded public IP when logging in through trusted Caddy", %{conn: conn} do
      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.12/32"])
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> put_private(:phoenix_endpoint, ElektrineWeb.Endpoint)
        |> Map.put(:remote_ip, {172, 30, 0, 12})
        |> put_req_header("x-forwarded-for", "203.0.113.88")
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn)
      assert Accounts.get_user!(user.id).last_login_ip == "203.0.113.88"
    end

    test "records the leftmost chain entry as login IP when every hop is a trusted proxy", %{
      conn: conn
    } do
      Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.0/24"])
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> put_private(:phoenix_endpoint, ElektrineWeb.Endpoint)
        |> Map.put(:remote_ip, {172, 30, 0, 1})
        |> put_req_header("x-forwarded-for", "172.30.0.1, 172.30.0.12")
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn)
      assert Accounts.get_user!(user.id).last_login_ip == "172.30.0.1"
    end

    test "allows admin access with a valid elevated session", %{conn: conn} do
      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})
      now = System.system_time(:second)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, "test-token")
        |> put_session(:admin_auth_method, "password")
        |> put_session(:admin_access_expires_at, now + 300)
        |> put_session(:admin_elevated_until, now + 120)
        |> assign(:current_user, admin)
        |> Map.put(:remote_ip, {203, 0, 113, 25})

      conn = UserAuth.require_admin_access(conn, [])

      refute conn.halted
      assert get_session(conn, :user_token) == "test-token"
    end

    test "redirects admin to elevation when elevation expires", %{conn: conn} do
      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})
      now = System.system_time(:second)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, "test-token")
        |> put_session(:admin_auth_method, "password")
        |> put_session(:admin_access_expires_at, now + 300)
        |> put_session(:admin_elevated_until, now - 1)
        |> assign(:current_user, admin)
        |> Map.put(:remote_ip, {203, 0, 113, 25})

      conn = UserAuth.require_admin_access(conn, [])

      assert conn.halted
      assert get_resp_header(conn, "location") != []

      assert String.starts_with?(
               hd(get_resp_header(conn, "location")),
               "/pripyat/security/elevate"
             )
    end
  end

  describe "require_admin_host/2" do
    test "allows the public apex when NetBird is disabled", %{conn: conn} do
      conn = %{conn | host: Elektrine.Domains.primary_profile_domain()}

      conn = UserAuth.require_admin_host(conn, [])

      refute conn.halted
    end

    test "returns 404 on the public apex when NetBird is enabled", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.64.1.0/24"])

      conn =
        conn
        |> fetch_query_params()
        |> Map.put(:host, Elektrine.Domains.primary_profile_domain())
        |> Map.put(:params, %{"_format" => "html"})

      conn = UserAuth.require_admin_host(conn, [])

      assert conn.halted
      assert conn.status == 404
    end

    test "allows the dedicated admin host", %{conn: conn} do
      conn = %{conn | host: "admin.#{Elektrine.Domains.primary_profile_domain()}"}

      conn = UserAuth.require_admin_host(conn, [])

      refute conn.halted
    end

    test "allows CADDY_ADMIN_HOST override", %{conn: conn} do
      original = System.get_env("CADDY_ADMIN_HOST")
      System.put_env("CADDY_ADMIN_HOST", "ops.example.test")

      on_exit(fn ->
        if original,
          do: System.put_env("CADDY_ADMIN_HOST", original),
          else: System.delete_env("CADDY_ADMIN_HOST")
      end)

      conn = %{conn | host: "ops.example.test"}

      conn = UserAuth.require_admin_host(conn, [])

      refute conn.halted
    end
  end

  describe "admin_login_restricted?/2" do
    test "does not restrict admin login when NetBird is disabled", %{conn: conn} do
      user = %{is_admin: true}

      conn = %{
        conn
        | host: Elektrine.Domains.primary_profile_domain(),
          remote_ip: {203, 0, 113, 10}
      }

      refute UserAuth.admin_login_restricted?(conn, user)
    end

    test "allows admin login from NetBird clients when NetBird is enabled", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.90.0.0/16"])

      user = %{is_admin: true}

      conn = %{
        conn
        | host: Elektrine.Domains.primary_profile_domain(),
          remote_ip: {100, 90, 10, 50}
      }

      refute UserAuth.admin_login_restricted?(conn, user)
    end

    test "restricts admin login on admin host when off VPN", %{
      conn: conn
    } do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.90.0.0/16"])

      user = %{is_admin: true}

      conn = %{
        conn
        | host: "admin.#{Elektrine.Domains.primary_profile_domain()}",
          remote_ip: {203, 0, 113, 50}
      }

      assert UserAuth.admin_login_restricted?(conn, user)
    end

    test "does not restrict non-admin login when NetBird is enabled", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.90.0.0/16"])

      user = %{is_admin: false}

      conn = %{
        conn
        | host: Elektrine.Domains.primary_profile_domain(),
          remote_ip: {203, 0, 113, 10}
      }

      refute UserAuth.admin_login_restricted?(conn, user)
    end
  end

  describe "require_vpn_when_netbird_enabled/2" do
    test "allows public clients when NetBird is disabled", %{conn: conn} do
      conn = %{conn | remote_ip: {203, 0, 113, 10}}

      conn = UserAuth.require_vpn_when_netbird_enabled(conn, [])

      refute conn.halted
    end

    test "allows NetBird clients when NetBird is enabled", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.64.1.0/24"])
      conn = %{conn | remote_ip: {100, 64, 1, 10}}

      conn = UserAuth.require_vpn_when_netbird_enabled(conn, [])

      refute conn.halted
    end

    test "returns 404 for admin host clients off VPN", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.64.1.0/24"])

      conn = %{
        conn
        | host: "admin.#{Elektrine.Domains.primary_profile_domain()}",
          remote_ip: {203, 0, 113, 10}
      }

      conn = UserAuth.require_vpn_when_netbird_enabled(conn, [])

      assert conn.halted
      assert conn.status == 404
    end

    test "returns 404 for public clients when NetBird is enabled", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.64.1.0/24"])
      conn = %{conn | remote_ip: {203, 0, 113, 10}}

      conn = UserAuth.require_vpn_when_netbird_enabled(conn, [])

      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "fetch_current_user/2" do
    test "rejects and revokes existing sessions after a user is banned", %{conn: conn} do
      user = user_fixture()

      logged_in_conn =
        conn
        |> init_test_session(%{})
        |> put_private(:phoenix_endpoint, ElektrineWeb.Endpoint)
        |> UserAuth.log_in_user(user)

      token = get_session(logged_in_conn, :user_token)
      session_id = get_session(logged_in_conn, :user_session_id)

      assert {:ok, _banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

      conn =
        build_conn()
        |> init_test_session(user_token: token, user_session_id: session_id)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
      assert conn.assigns.current_user_session == nil
      assert get_session(conn, :user_token) == nil
      assert get_session(conn, :user_session_id) == nil
      assert Accounts.get_active_user_session(user.id, session_id) == nil
    end

    test "does not log in a banned user", %{conn: conn} do
      user = user_fixture()
      {:ok, banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

      conn =
        conn
        |> init_test_session(%{})
        |> put_private(:phoenix_endpoint, ElektrineWeb.Endpoint)
        |> UserAuth.log_in_user(banned_user)

      assert redirected_to(conn) == Elektrine.Paths.login_path()
      assert get_session(conn, :user_token) == nil
      assert get_session(conn, :user_session_id) == nil
    end

    test "does not return a banned user from two-factor handoff", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> UserAuth.store_user_for_two_factor_verification(user)

      assert {:ok, _banned_user} = Accounts.ban_user(user, %{banned_reason: "security test"})

      assert UserAuth.get_user_for_two_factor_verification(conn) == nil
    end

    test "tracks browser sessions and rejects revoked sessions", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> put_private(:phoenix_endpoint, ElektrineWeb.Endpoint)
        |> put_req_header(
          "user-agent",
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126 Safari/537.36"
        )
        |> UserAuth.log_in_user(user)

      token = get_session(conn, :user_token)
      session_id = get_session(conn, :user_session_id)

      assert is_binary(token)
      assert is_integer(session_id)

      assert %{browser: "Chrome", platform: "macOS"} =
               Accounts.get_active_user_session(user.id, session_id)

      conn =
        build_conn()
        |> init_test_session(user_token: token)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_user_session.id == session_id

      assert {:ok, _} = Accounts.revoke_user_session(user.id, session_id)

      conn =
        build_conn()
        |> init_test_session(user_token: token)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
      assert conn.assigns.current_user_session == nil
    end

    test "logout revokes only the current tracked session", %{conn: conn} do
      user = user_fixture()
      {:ok, other_session} = Accounts.create_user_session(user, %{auth_method: "password"})

      logged_in_conn =
        conn
        |> init_test_session(%{})
        |> put_private(:phoenix_endpoint, ElektrineWeb.Endpoint)
        |> UserAuth.log_in_user(user)

      token = get_session(logged_in_conn, :user_token)
      current_session_id = get_session(logged_in_conn, :user_session_id)

      conn =
        build_conn()
        |> init_test_session(user_token: token, user_session_id: current_session_id)
        |> UserAuth.fetch_current_user([])

      conn = UserAuth.log_out_user(conn)

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_active_user_session(user.id, current_session_id) == nil
      assert Accounts.get_active_user_session(user.id, other_session.id)
    end

    test "clears admin sessions on admin host when off VPN", %{
      conn: conn
    } do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.90.0.0/16"])

      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})

      token =
        Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
          "user_id" => admin.id,
          "password_changed_at" => DateTime.to_unix(admin.last_password_change),
          "auth_valid_after" => admin.auth_valid_after && DateTime.to_unix(admin.auth_valid_after)
        })

      conn =
        conn
        |> init_test_session(user_token: token)
        |> Map.put(:host, "admin.#{Elektrine.Domains.primary_profile_domain()}")
        |> Map.put(:remote_ip, {203, 0, 113, 50})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
      assert get_session(conn, :user_token) == nil
    end

    test "rejects sessions issued before the last password change", %{conn: conn} do
      user = user_fixture()

      stale_token =
        Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
          "user_id" => user.id,
          "password_changed_at" =>
            DateTime.to_unix(DateTime.add(user.last_password_change, -60, :second)),
          "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
        })

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, stale_token)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "clears admin sessions off VPN when NetBird is enabled", %{conn: conn} do
      Application.put_env(:elektrine, :netbird, enabled: true, allowed_cidrs: ["100.64.1.0/24"])
      user = user_fixture()
      {:ok, admin} = Accounts.admin_update_user(user, %{is_admin: true})

      token =
        Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
          "user_id" => admin.id,
          "password_changed_at" => DateTime.to_unix(admin.last_password_change),
          "auth_valid_after" => admin.auth_valid_after && DateTime.to_unix(admin.auth_valid_after)
        })

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, token)
        |> Map.put(:remote_ip, {203, 0, 113, 10})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
      assert get_session(conn, :user_token) == nil
    end
  end
end
