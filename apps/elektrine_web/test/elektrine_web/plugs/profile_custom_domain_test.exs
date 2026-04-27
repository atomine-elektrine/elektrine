defmodule ElektrineWeb.Plugs.ProfileCustomDomainTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.DNS
  alias Elektrine.Profiles.CustomDomain
  alias Elektrine.Repo
  alias ElektrineWeb.Plugs.ProfileCustomDomain

  test "ignores forwarded host headers for custom domain routing" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "internal-server")
      |> Plug.Conn.put_req_header("x-forwarded-host", "verified.example.com")
      |> ProfileCustomDomain.call([])

    refute conn.assigns[:profile_custom_domain]
    refute conn.assigns[:subdomain_handle]
    assert conn.host == "internal-server"
  end

  test "redirects plain-http verified custom domains to https when managed DNS web service enables it" do
    user = user_fixture(%{username: "dnsforcehttps"})
    custom_domain = "force-https-#{System.unique_integer([:positive])}.example.test"

    Repo.insert!(%CustomDomain{
      domain: custom_domain,
      verification_token: "verify-force-https",
      status: "verified",
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
      user_id: user.id
    })

    {:ok, zone} = DNS.create_zone(user, %{"domain" => custom_domain})

    {:ok, _zone} = DNS.update_zone(zone, %{"force_https" => true})

    assert DNS.web_force_https_for_host(custom_domain)

    conn =
      Plug.Test.conn(:get, "/posts?page=2")
      |> Map.put(:scheme, :http)
      |> Map.put(:host, custom_domain)
      |> ProfileCustomDomain.call([])

    assert conn.status in [301, 302]
    assert get_resp_header(conn, "location") == ["https://#{custom_domain}/posts?page=2"]
  end

  test "does not loop force-https redirects when Caddy already forwarded HTTPS" do
    previous_trusted_proxy_cidrs = Application.get_env(:elektrine, :trusted_proxy_cidrs, [])

    on_exit(fn ->
      Application.put_env(:elektrine, :trusted_proxy_cidrs, previous_trusted_proxy_cidrs)
    end)

    Application.put_env(:elektrine, :trusted_proxy_cidrs, ["172.30.0.12/32"])

    user = user_fixture(%{username: "dnsforwardedhttps"})
    custom_domain = "forwarded-https-#{System.unique_integer([:positive])}.example.test"

    Repo.insert!(%CustomDomain{
      domain: custom_domain,
      verification_token: "verify-forwarded-https",
      status: "verified",
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
      user_id: user.id
    })

    {:ok, zone} = DNS.create_zone(user, %{"domain" => custom_domain})
    {:ok, _zone} = DNS.update_zone(zone, %{"force_https" => true})

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:scheme, :http)
      |> Map.put(:remote_ip, {172, 30, 0, 12})
      |> Map.put(:host, custom_domain)
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> ProfileCustomDomain.call([])

    refute conn.status in [301, 302]
    assert conn.assigns[:profile_custom_domain] == custom_domain
  end
end
