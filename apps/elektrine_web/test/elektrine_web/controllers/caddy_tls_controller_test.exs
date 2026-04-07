defmodule ElektrineWeb.CaddyTLSControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Profiles.CustomDomain
  alias Elektrine.Repo

  setup %{conn: conn} do
    previous_api_key = System.get_env("CADDY_EDGE_API_KEY")
    previous_enforce_https = Application.get_env(:elektrine, :enforce_https)
    api_key = "test-caddy-edge-api-key"

    System.put_env("CADDY_EDGE_API_KEY", api_key)

    on_exit(fn ->
      if is_nil(previous_api_key) do
        System.delete_env("CADDY_EDGE_API_KEY")
      else
        System.put_env("CADDY_EDGE_API_KEY", previous_api_key)
      end

      Application.put_env(:elektrine, :enforce_https, previous_enforce_https)
    end)

    {:ok, conn: conn, api_key: api_key}
  end

  describe "GET /_edge/tls/v1/allow" do
    test "requires the Caddy edge API key" do
      conn = get(build_conn(), "/_edge/tls/v1/allow?domain=example.test")
      assert conn.status == 401
    end

    test "accepts the API key from the token query parameter for Caddy ask URLs", %{
      conn: conn,
      api_key: api_key
    } do
      user = user_fixture(%{username: "caddyquerytoken"})
      verified_domain = "caddyquerytoken.test"

      Repo.insert!(%CustomDomain{
        domain: verified_domain,
        verification_token: "verify-caddy-query-token",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn =
        conn
        |> Map.put(
          :host,
          Application.get_env(:elektrine, :primary_domain, "example.com") |> to_string()
        )
        |> get(allow_path(verified_domain) <> "&token=#{URI.encode_www_form(api_key)}")

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "accepts query tokens containing plus signs", %{conn: conn} do
      previous_api_key = System.get_env("CADDY_EDGE_API_KEY")
      api_key = "/VbQ0L7nEvvhZv3ZoPlY2E+i5XpNkI0mLOzQadl1zFA="
      user = user_fixture(%{username: "caddyqueryplus"})
      verified_domain = "caddyqueryplus.test"

      System.put_env("CADDY_EDGE_API_KEY", api_key)

      on_exit(fn ->
        if is_nil(previous_api_key) do
          System.delete_env("CADDY_EDGE_API_KEY")
        else
          System.put_env("CADDY_EDGE_API_KEY", previous_api_key)
        end
      end)

      Repo.insert!(%CustomDomain{
        domain: verified_domain,
        verification_token: "verify-caddy-query-plus",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn =
        conn
        |> Map.put(
          :host,
          Application.get_env(:elektrine, :primary_domain, "example.com") |> to_string()
        )
        |> get(allow_path(verified_domain) <> "&token=#{api_key}")

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "allows verified custom profile domains", %{conn: conn, api_key: api_key} do
      user = user_fixture(%{username: "caddyverified"})
      verified_domain = "caddyverified.test"

      Repo.insert!(%CustomDomain{
        domain: verified_domain,
        verification_token: "verify-caddy-verified",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn = conn |> auth_conn(api_key) |> get(allow_path(verified_domain))

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "allows www aliases for verified custom domains", %{conn: conn, api_key: api_key} do
      user = user_fixture(%{username: "caddywww"})
      verified_domain = "caddywww.test"

      Repo.insert!(%CustomDomain{
        domain: verified_domain,
        verification_token: "verify-caddy-www",
        status: "verified",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        user_id: user.id
      })

      conn = conn |> auth_conn(api_key) |> get(allow_path("www.#{verified_domain}"))

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "allows built-in mta-sts domains", %{conn: conn, api_key: api_key} do
      previous_email = Application.get_env(:elektrine, :email, [])
      domain = Application.get_env(:elektrine, :primary_domain, "example.com") |> to_string()

      Application.put_env(
        :elektrine,
        :email,
        Keyword.put(previous_email, :supported_domains, [domain])
      )

      on_exit(fn -> Application.put_env(:elektrine, :email, previous_email) end)

      conn = conn |> auth_conn(api_key) |> get(allow_path("mta-sts.#{domain}"))

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "allows built-in profile subdomains only for real user handles", %{
      conn: conn,
      api_key: api_key
    } do
      user = user_fixture(%{username: "caddyhandle"})
      {:ok, _user} = Accounts.update_user_handle(user, "caddyhandle")
      previous_profile_domains = Application.get_env(:elektrine, :profile_base_domains, [])

      Application.put_env(:elektrine, :profile_base_domains, ["example.com"])

      on_exit(fn ->
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_domains)
      end)

      conn = conn |> auth_conn(api_key) |> get(allow_path("caddyhandle.example.com"))

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "rejects nonexistent built-in profile subdomains", %{conn: conn, api_key: api_key} do
      previous_profile_domains = Application.get_env(:elektrine, :profile_base_domains, [])

      Application.put_env(:elektrine, :profile_base_domains, ["example.com"])

      on_exit(fn ->
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_domains)
      end)

      conn = conn |> auth_conn(api_key) |> get(allow_path("missing.example.com"))

      assert conn.status == 403
      assert response(conn, 403) == "forbidden"
    end

    test "rejects multi-label built-in profile subdomains", %{conn: conn, api_key: api_key} do
      previous_profile_domains = Application.get_env(:elektrine, :profile_base_domains, [])

      Application.put_env(:elektrine, :profile_base_domains, ["example.com"])

      on_exit(fn ->
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_domains)
      end)

      conn = conn |> auth_conn(api_key) |> get(allow_path("foo.bar.example.com"))

      assert conn.status == 403
      assert response(conn, 403) == "forbidden"
    end

    test "rejects unknown domains", %{conn: conn, api_key: api_key} do
      conn = conn |> auth_conn(api_key) |> get(allow_path("unknown-profile-domain.test"))

      assert conn.status == 403
      assert response(conn, 403) == "forbidden"
    end

    test "rejects pending domains", %{conn: conn, api_key: api_key} do
      user = user_fixture(%{username: "caddypending"})
      pending_domain = "caddypending.test"

      Repo.insert!(%CustomDomain{
        domain: pending_domain,
        verification_token: "verify-caddy-pending",
        status: "pending",
        user_id: user.id
      })

      conn = conn |> auth_conn(api_key) |> get(allow_path(pending_domain))

      assert conn.status == 403
      assert response(conn, 403) == "forbidden"
    end

    test "returns bad request when domain is missing", %{conn: conn, api_key: api_key} do
      conn = conn |> auth_conn(api_key) |> get("/_edge/tls/v1/allow")

      assert conn.status == 400
      assert response(conn, 400) == "missing domain"
    end

    test "does not redirect the internal allow endpoint when HTTPS enforcement is enabled", %{
      conn: conn,
      api_key: api_key
    } do
      Application.put_env(:elektrine, :enforce_https, true)

      conn = conn |> auth_conn(api_key) |> get("/_edge/tls/v1/allow")

      assert conn.status == 400
      assert response(conn, 400) == "missing domain"
      assert get_resp_header(conn, "location") == []
    end
  end

  defp auth_conn(conn, api_key) do
    Plug.Conn.put_req_header(conn, "x-api-key", api_key)
    |> Map.put(
      :host,
      Application.get_env(:elektrine, :primary_domain, "example.com") |> to_string()
    )
  end

  defp allow_path(domain) do
    "/_edge/tls/v1/allow?domain=#{URI.encode_www_form(domain)}"
  end
end
