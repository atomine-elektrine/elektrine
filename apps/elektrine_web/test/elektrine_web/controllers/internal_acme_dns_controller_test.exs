defmodule ElektrineWeb.InternalACMEDNSControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS

  setup %{conn: conn} do
    previous_api_key = System.get_env("CADDY_EDGE_API_KEY")
    api_key = "test-acme-internal-api-key"

    System.put_env("CADDY_EDGE_API_KEY", api_key)

    on_exit(fn ->
      if is_nil(previous_api_key) do
        System.delete_env("CADDY_EDGE_API_KEY")
      else
        System.put_env("CADDY_EDGE_API_KEY", previous_api_key)
      end
    end)

    user = AccountsFixtures.user_fixture()
    domain = "acme-#{System.unique_integer([:positive])}.example"
    {:ok, zone} = DNS.create_zone(user, %{"domain" => domain})

    {:ok, conn: conn, api_key: api_key, zone: zone}
  end

  describe "POST /_edge/acme/dns/v1/txt" do
    test "requires internal auth" do
      conn = post(build_conn(), "/_edge/acme/dns/v1/txt", %{})

      assert conn.status == 401
    end

    test "creates TXT record for matching zone", %{conn: conn, api_key: api_key, zone: zone} do
      conn =
        conn
        |> auth_conn(api_key)
        |> post("/_edge/acme/dns/v1/txt", %{
          "domain" => "_acme-challenge.#{zone.domain}",
          "value" => "challenge-value"
        })

      assert %{"record" => %{"name" => "_acme-challenge"}} = json_response(conn, 200)

      zone = DNS.get_zone_by_domain(zone.domain)

      assert Enum.any?(
               zone.records,
               &(&1.name == "_acme-challenge" and &1.content == "challenge-value")
             )
    end

    test "rejects non-ACME TXT names", %{conn: conn, api_key: api_key, zone: zone} do
      conn =
        conn
        |> auth_conn(api_key)
        |> post("/_edge/acme/dns/v1/txt", %{
          "domain" => "not-acme.#{zone.domain}",
          "value" => "challenge-value"
        })

      assert %{"error" => "invalid_challenge_name"} = json_response(conn, 400)
    end
  end

  describe "DELETE /_edge/acme/dns/v1/txt" do
    test "removes only the matching TXT record", %{conn: conn, api_key: api_key, zone: zone} do
      {:ok, _record} =
        DNS.create_record(zone, %{
          "name" => "_acme-challenge",
          "type" => "TXT",
          "ttl" => 60,
          "content" => "remove-me"
        })

      {:ok, _record} =
        DNS.create_record(zone, %{
          "name" => "_acme-challenge",
          "type" => "TXT",
          "ttl" => 60,
          "content" => "keep-me"
        })

      conn =
        conn
        |> auth_conn(api_key)
        |> delete("/_edge/acme/dns/v1/txt", %{
          "domain" => "_acme-challenge.#{zone.domain}",
          "value" => "remove-me"
        })

      assert %{"removed" => true} = json_response(conn, 200)

      zone = DNS.get_zone_by_domain(zone.domain)
      refute Enum.any?(zone.records, &(&1.content == "remove-me"))
      assert Enum.any?(zone.records, &(&1.content == "keep-me"))
    end
  end

  defp auth_conn(conn, api_key) do
    Plug.Conn.put_req_header(conn, "x-api-key", api_key)
  end
end
