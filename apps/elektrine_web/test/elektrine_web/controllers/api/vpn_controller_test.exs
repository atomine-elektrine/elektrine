defmodule ElektrineWeb.API.VPNControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.{Accounts, VPN}
  alias ElektrineWeb.Plugs.APIAuth

  setup %{conn: conn} do
    {:ok, user} =
      Accounts.create_user(%{
        username: "vpnapi#{System.unique_integer([:positive])}",
        password: "hello world!",
        password_confirmation: "hello world!"
      })

    {:ok, token} = APIAuth.generate_token(user.id)
    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    {:ok, conn: conn, user: user}
  end

  test "create_config returns shadowsocks protocol metadata and config payload", %{
    conn: conn,
    user: _user
  } do
    {:ok, server} =
      VPN.create_server(%{
        name: "Singapore SS",
        protocol: "shadowsocks",
        location: "Singapore",
        public_ip: "198.51.100.90",
        endpoint_port: 8388,
        metadata: %{"cipher" => "chacha20-ietf-poly1305"}
      })

    conn = post(conn, "/api/vpn/configs", %{server_id: server.id})
    response = json_response(conn, 201)

    assert response["config_content"] =~ "ss://"
    assert response["wireguard_config"] == nil
    assert response["config"]["protocol"] == "shadowsocks"
    assert response["config"]["server"]["protocol"] == "shadowsocks"
    assert response["config"]["server"]["protocol_label"] == "Shadowsocks"
  end

  test "show_config returns shadowsocks config payload", %{conn: conn, user: user} do
    {:ok, server} =
      VPN.create_server(%{
        name: "Seoul SS",
        protocol: "shadowsocks",
        location: "Seoul",
        public_ip: "198.51.100.91",
        endpoint_port: 443,
        metadata: %{"cipher" => "aes-256-gcm"}
      })

    {:ok, config} = VPN.create_user_config(user.id, server.id)

    conn = get(conn, "/api/vpn/configs/#{config.id}")
    response = json_response(conn, 200)

    assert response["config_content"] =~ "ss://"
    assert response["config"]["server"]["endpoint_port"] == 443
    assert response["config"]["server"]["protocol"] == "shadowsocks"
  end

  test "server listing includes protocol metadata", %{conn: conn} do
    {:ok, _server} =
      VPN.create_server(%{
        name: "HK SS",
        protocol: "shadowsocks",
        location: "Hong Kong",
        public_ip: "198.51.100.92",
        endpoint_port: 8388,
        metadata: %{"cipher" => "chacha20-ietf-poly1305"}
      })

    conn = get(conn, "/api/vpn/servers")
    response = json_response(conn, 200)

    assert Enum.any?(response["servers"], fn server ->
             server["protocol"] == "shadowsocks" and server["protocol_label"] == "Shadowsocks"
           end)
  end
end
