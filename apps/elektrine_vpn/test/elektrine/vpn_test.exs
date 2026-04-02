defmodule Elektrine.VPNTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.{Accounts, VPN}

  describe "generate_config_file/1" do
    test "uses endpoint host override and client mtu when present" do
      user = user_fixture()

      {:ok, server} =
        VPN.create_server(%{
          name: "HK Edge",
          location: "Hong Kong",
          public_ip: "198.51.100.10",
          endpoint_host: "hk-vpn.example.com",
          public_key: "server-public-key-1",
          endpoint_port: 443,
          client_mtu: 1280,
          internal_ip_range: "10.8.0.0/24"
        })

      {:ok, config} = VPN.create_user_config(user.id, server.id)

      config_file = VPN.generate_config_file(config)

      assert config_file =~ "Endpoint = hk-vpn.example.com:443"
      assert config_file =~ "MTU = 1280"
    end

    test "falls back to public ip and omits mtu when unset" do
      user = user_fixture()

      {:ok, server} =
        VPN.create_server(%{
          name: "US East",
          location: "Virginia",
          public_ip: "198.51.100.11",
          endpoint_host: "",
          public_key: "server-public-key-2",
          endpoint_port: 51_820,
          client_mtu: nil,
          internal_ip_range: "10.9.0.0/24"
        })

      {:ok, config} = VPN.create_user_config(user.id, server.id)

      config_file = VPN.generate_config_file(config)

      assert config_file =~ "Endpoint = 198.51.100.11:51820"
      refute config_file =~ "MTU ="
    end
  end

  describe "auto_register_server/1" do
    test "defaults to udp 443 and a low mtu" do
      {:ok, server} =
        VPN.auto_register_server(%{
          name: "Auto Edge",
          location: "Singapore",
          public_ip: "203.0.113.20",
          public_key: "server-public-key-3"
        })

      assert server.endpoint_port == 443
      assert server.client_mtu == 1280
    end
  end

  describe "ensure_self_host_server/1" do
    test "creates a managed self-hosted server from env" do
      {:ok, server} =
        VPN.ensure_self_host_server(%{
          "PRIMARY_DOMAIN" => "example.com",
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.50",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key"
        })

      assert server.name == "example.com"
      assert server.location == "Self-hosted"
      assert server.public_ip == "203.0.113.50"
      assert server.endpoint_port == 443
      assert server.client_mtu == 1280
      assert VPN.self_host_server?(server)
      assert is_binary(server.api_key)
    end

    test "updates the managed self-hosted server in place" do
      {:ok, original} =
        VPN.ensure_self_host_server(%{
          "PRIMARY_DOMAIN" => "example.com",
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.51",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key-a"
        })

      {:ok, updated} =
        VPN.ensure_self_host_server(%{
          "VPN_SELFHOST_NAME" => "Home VPN",
          "VPN_SELFHOST_LOCATION" => "Closet rack",
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.51",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key-b",
          "VPN_SELFHOST_ENDPOINT_HOST" => "vpn.example.com"
        })

      assert updated.id == original.id
      assert updated.api_key == original.api_key
      assert updated.name == "Home VPN"
      assert updated.location == "Closet rack"
      assert updated.public_key == "self-host-public-key-b"
      assert updated.endpoint_host == "vpn.example.com"
    end
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        username: unique_user_username(),
        password: valid_user_password(),
        password_confirmation: valid_user_password()
      })

    user
  end

  defp unique_user_username, do: "vpnuser#{System.unique_integer([:positive])}"
  defp valid_user_password, do: "hello world!"
end
