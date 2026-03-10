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
