defmodule ElektrineWeb.InternalDNSControllerTest do
  use ElektrineWeb.ConnCase, async: false

  setup %{conn: conn} do
    previous_api_key = System.get_env("CADDY_EDGE_API_KEY")
    api_key = "test-dns-health-api-key"

    System.put_env("CADDY_EDGE_API_KEY", api_key)

    on_exit(fn ->
      if is_nil(previous_api_key) do
        System.delete_env("CADDY_EDGE_API_KEY")
      else
        System.put_env("CADDY_EDGE_API_KEY", previous_api_key)
      end
    end)

    {:ok, conn: conn, api_key: api_key}
  end

  test "requires internal auth" do
    conn = get(build_conn(), "/_edge/dns/v1/health")

    assert conn.status == 401
  end

  test "returns DNS health payload", %{conn: conn, api_key: api_key} do
    conn =
      conn
      |> Plug.Conn.put_req_header("x-api-key", api_key)
      |> get("/_edge/dns/v1/health")

    assert conn.status in [200, 503]

    assert %{
             "status" => status,
             "zone_cache_running" => zone_cache_running,
             "nameservers_configured" => nameservers_configured,
             "authority_enabled" => authority_enabled,
             "recursive_enabled" => recursive_enabled
           } = json_response(conn, conn.status)

    assert status in ["ok", "error"]
    assert is_boolean(zone_cache_running)
    assert is_boolean(nameservers_configured)
    assert is_boolean(authority_enabled)
    assert is_boolean(recursive_enabled)
  end
end
