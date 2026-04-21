defmodule ElektrineWeb.VPNAPIControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.{Accounts, VPN}

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "vpnnode#{System.unique_integer([:positive])}",
        password: "hello world!",
        password_confirmation: "hello world!"
      })

    {:ok, server} =
      VPN.create_server(%{
        name: "Managed SS",
        protocol: "shadowsocks",
        location: "Osaka",
        public_ip: "198.51.100.93",
        endpoint_port: 8388,
        api_key: "node-api-key",
        metadata: %{"cipher" => "chacha20-ietf-poly1305"}
      })

    {:ok, config} = VPN.create_user_config(user.id, server.id)
    conn = put_req_header(conn, "authorization", "Bearer node-api-key")

    {:ok, conn: conn, server: server, config: config}
  end

  test "get_peers returns shadowsocks clients for managed nodes", %{
    conn: conn,
    server: server,
    config: config
  } do
    conn = get(conn, "/api/vpn/#{server.id}/peers")
    response = json_response(conn, 200)

    assert response["protocol"] == "shadowsocks"
    assert response["server"]["cipher"] == "chacha20-ietf-poly1305"

    assert [client] = response["clients"]
    assert client["client_id"] == config.public_key
    assert is_binary(client["password"])
    assert client["cipher"] == "chacha20-ietf-poly1305"
    assert response["peers"] == []
  end

  test "update_stats accepts shadowsocks client stats", %{
    conn: conn,
    server: server,
    config: config
  } do
    conn =
      post(conn, "/api/vpn/#{server.id}/stats", %{
        clients: [
          %{
            client_id: config.public_key,
            uploaded_bytes: 1234,
            downloaded_bytes: 5678,
            last_seen_at:
              DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          }
        ]
      })

    response = json_response(conn, 200)
    stats = wait_for_server_stats(server.id)

    assert response["protocol"] == "shadowsocks"
    assert response["updated"] == 1
    assert stats.bytes_sent == 1234
    assert stats.bytes_received == 5678
  end

  test "register_key rejects shadowsocks servers", %{conn: conn, server: server} do
    conn = post(conn, "/api/vpn/#{server.id}/register-key", %{public_key: "ignored"})

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "only supported for WireGuard"
  end

  defp wait_for_server_stats(server_id, attempts \\ 20)

  defp wait_for_server_stats(server_id, attempts) when attempts > 0 do
    stats = VPN.StatsAggregator.get_server_stats(server_id)

    if stats.bytes_sent == 0 and stats.bytes_received == 0 do
      Process.sleep(25)
      wait_for_server_stats(server_id, attempts - 1)
    else
      stats
    end
  end

  defp wait_for_server_stats(server_id, 0), do: VPN.StatsAggregator.get_server_stats(server_id)
end
