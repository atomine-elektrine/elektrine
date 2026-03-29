defmodule ElektrineWeb.CaddyTLSControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

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

      conn = get(conn, allow_path(api_key, verified_domain))

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

      conn = get(conn, allow_path(api_key, "www.#{verified_domain}"))

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

      conn = get(conn, allow_path(api_key, "mta-sts.#{domain}"))

      assert conn.status == 200
      assert response(conn, 200) == "allowed"
    end

    test "rejects unknown domains", %{conn: conn, api_key: api_key} do
      conn = get(conn, allow_path(api_key, "unknown-profile-domain.test"))

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

      conn = get(conn, allow_path(api_key, pending_domain))

      assert conn.status == 403
      assert response(conn, 403) == "forbidden"
    end

    test "returns bad request when domain is missing", %{conn: conn, api_key: api_key} do
      conn = get(conn, "/_edge/tls/v1/allow?token=#{URI.encode_www_form(api_key)}")

      assert conn.status == 400
      assert response(conn, 400) == "missing domain"
    end

    test "does not redirect the internal allow endpoint when HTTPS enforcement is enabled", %{
      conn: conn,
      api_key: api_key
    } do
      Application.put_env(:elektrine, :enforce_https, true)

      conn = get(conn, "/_edge/tls/v1/allow?token=#{URI.encode_www_form(api_key)}")

      assert conn.status == 400
      assert response(conn, 400) == "missing domain"
      assert get_resp_header(conn, "location") == []
    end
  end

  defp allow_path(api_key, domain) do
    "/_edge/tls/v1/allow?token=#{URI.encode_www_form(api_key)}&domain=#{URI.encode_www_form(domain)}"
  end
end
