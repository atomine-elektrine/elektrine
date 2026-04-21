defmodule ElektrineWeb.API.VPNRegistrationControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.VPN

  setup do
    previous = System.get_env("VPN_FLEET_REGISTRATION_KEY")
    System.put_env("VPN_FLEET_REGISTRATION_KEY", "fleet-test-key")

    on_exit(fn ->
      if previous do
        System.put_env("VPN_FLEET_REGISTRATION_KEY", previous)
      else
        System.delete_env("VPN_FLEET_REGISTRATION_KEY")
      end
    end)

    :ok
  end

  test "auto registration does not return existing server credentials", %{conn: conn} do
    {:ok, server} =
      VPN.auto_register_server(%{
        name: "Existing Edge",
        location: "Virginia",
        public_ip: "203.0.113.30",
        public_key: "existing-public-key",
        internal_ip_range: "10.20.0.0/24"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer fleet-test-key")
      |> post("/api/vpn/register", %{
        name: "Existing Edge",
        location: "Virginia",
        public_ip: "203.0.113.30",
        public_key: "attacker-public-key"
      })

    response = json_response(conn, 409)

    assert %{"server_id" => server_id, "message" => message} = response
    assert server_id == server.id
    assert message =~ "cannot be recovered"
    refute Map.has_key?(response, "api_key")
  end

  test "auto registration accepts Shadowsocks servers and applies defaults", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer fleet-test-key")
      |> post("/api/vpn/register", %{
        name: "Tokyo SS",
        protocol: "shadowsocks",
        location: "Tokyo",
        public_ip: "203.0.113.40",
        metadata: %{"cipher" => "aes-256-gcm"}
      })

    response = json_response(conn, 200)
    server = VPN.get_server!(response["server_id"])

    assert response["status"] == "registered"
    assert is_binary(response["api_key"])
    assert server.protocol == "shadowsocks"
    assert server.endpoint_port == 8388
    assert server.public_key == "shadowsocks"
    assert server.internal_ip_range == "0.0.0.0/32"
    assert server.metadata["cipher"] == "aes-256-gcm"
  end
end
