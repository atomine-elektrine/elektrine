defmodule Elektrine.VPNTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.{Accounts, VPN}
  alias Elektrine.Repo

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
          endpoint_port: 51_820,
          client_mtu: 1280,
          internal_ip_range: "10.8.0.0/24"
        })

      {:ok, config} = VPN.create_user_config(user.id, server.id)

      config_file = VPN.generate_config_file(config)

      assert config_file =~ "Endpoint = hk-vpn.example.com:51820"
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

    test "generates a Shadowsocks URI for shadowsocks servers" do
      user = user_fixture()

      {:ok, server} =
        VPN.create_server(%{
          name: "Tokyo SS",
          protocol: "shadowsocks",
          location: "Tokyo",
          public_ip: "198.51.100.30",
          endpoint_port: 8388,
          metadata: %{
            "cipher" => "chacha20-ietf-poly1305",
            "port_range_start" => 8388,
            "port_range_end" => 8398
          }
        })

      {:ok, config} = VPN.create_user_config(user.id, server.id)

      config_file = VPN.generate_config_file(config)

      assert config_file =~ "ss://"
      assert config_file =~ "@198.51.100.30:8388"
      assert config_file =~ "#Tokyo+SS"
      assert VPN.config_download_filename(config) =~ ".txt"
    end

    test "allocates distinct Shadowsocks ports per user config" do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, server} =
        VPN.create_server(%{
          name: "Singapore SS",
          protocol: "shadowsocks",
          location: "Singapore",
          public_ip: "198.51.100.31",
          endpoint_port: 9000,
          metadata: %{
            "cipher" => "chacha20-ietf-poly1305",
            "port_range_start" => 9000,
            "port_range_end" => 9005
          }
        })

      {:ok, config_a} = VPN.create_user_config(user.id, server.id)
      {:ok, config_b} = VPN.create_user_config(other_user.id, server.id)

      assert VPN.shadowsocks_port(config_a) == 9000
      assert VPN.shadowsocks_port(config_b) == 9001
      assert VPN.generate_config_file(config_b) =~ "@198.51.100.31:9001"
    end
  end

  describe "auto_register_server/1" do
    test "defaults to udp 51820 and a low mtu" do
      {:ok, server} =
        VPN.auto_register_server(%{
          name: "Auto Edge",
          location: "Singapore",
          public_ip: "203.0.113.20",
          public_key: "server-public-key-3"
        })

      assert server.endpoint_port == 51_820
      assert server.client_mtu == 1280
    end

    test "uses Shadowsocks defaults for shadowsocks protocol" do
      {:ok, server} =
        VPN.auto_register_server(%{
          name: "Auto SS",
          protocol: "shadowsocks",
          location: "Taipei",
          public_ip: "203.0.113.21"
        })

      assert server.endpoint_port == 8388
      assert server.internal_ip_range == "0.0.0.0/32"
      assert server.metadata["cipher"] == "chacha20-ietf-poly1305"
    end
  end

  describe "server API keys" do
    test "stores generated API keys hashed at rest" do
      raw_api_key = "vpn-server-api-key"

      {:ok, server} =
        VPN.create_server(%{
          name: "Secure Edge",
          location: "Frankfurt",
          public_ip: "198.51.100.12",
          public_key: "server-public-key-4",
          internal_ip_range: "10.10.0.0/24",
          api_key: raw_api_key
        })

      assert String.starts_with?(server.api_key, "sha256:")
      assert VPN.valid_server_api_key?(server, raw_api_key)
      refute VPN.valid_server_api_key?(server, "wrong-key")
    end
  end

  describe "create_user_config/2" do
    test "rejects servers above the user's trust level" do
      user = user_fixture()

      {:ok, server} =
        VPN.create_server(%{
          name: "Trusted Edge",
          location: "Tokyo",
          public_ip: "198.51.100.13",
          public_key: "server-public-key-5",
          internal_ip_range: "10.11.0.0/24",
          minimum_trust_level: 2
        })

      assert {:error, :insufficient_trust_level} = VPN.create_user_config(user.id, server.id)

      Repo.update_all(Ecto.Query.from(u in Elektrine.Accounts.User, where: u.id == ^user.id),
        set: [trust_level: 2]
      )

      assert {:ok, _config} = VPN.create_user_config(user.id, server.id)
    end
  end

  describe "ensure_self_host_server/1" do
    test "returns existing managed self-host server when env keys are absent" do
      {:ok, original} =
        VPN.ensure_self_host_server(%{
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.60",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key-existing"
        })

      assert VPN.self_host_server?(original)

      assert {:ok, existing} = VPN.ensure_self_host_server(%{})
      assert existing.id == original.id
      assert existing.public_ip == "203.0.113.60"
    end

    test "creates a managed self-hosted server from env" do
      {:ok, server} =
        VPN.ensure_self_host_server(%{
          "PRIMARY_DOMAIN" => "example.com",
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.50",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key",
          "VPN_SELFHOST_LISTEN_PORT" => "51820"
        })

      assert server.name == "example.com"
      assert server.location == "Self-hosted"
      assert server.public_ip == "203.0.113.50"
      assert server.endpoint_port == 51_820
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

    test "prefers explicit endpoint port over listen port" do
      {:ok, server} =
        VPN.ensure_self_host_server(%{
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.52",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key-c",
          "VPN_SELFHOST_LISTEN_PORT" => "51820",
          "VPN_SELFHOST_ENDPOINT_PORT" => "443"
        })

      assert server.endpoint_port == 443
    end

    test "creates a managed self-hosted shadowsocks server from env" do
      {:ok, server} =
        VPN.ensure_self_host_server(%{
          "PRIMARY_DOMAIN" => "example.com",
          "VPN_SELFHOST_PROTOCOL" => "shadowsocks",
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.53",
          "VPN_SELFHOST_SS_LISTEN_PORT" => "8388",
          "VPN_SELFHOST_SS_PORT_RANGE_START" => "8388",
          "VPN_SELFHOST_SS_PORT_RANGE_END" => "8400"
        })

      assert server.protocol == "shadowsocks"
      assert server.endpoint_port == 8388
      assert server.public_key == "shadowsocks"
      assert server.metadata["cipher"] == "chacha20-ietf-poly1305"
      assert server.metadata["port_range_start"] == "8388"
      assert server.metadata["port_range_end"] == "8400"
    end

    test "creates both wireguard and shadowsocks self-hosted servers on the same host" do
      {:ok, servers} =
        VPN.ensure_self_host_servers(%{
          "PRIMARY_DOMAIN" => "example.com",
          "VPN_SELFHOST_PROTOCOLS" => "wireguard,shadowsocks",
          "VPN_SELFHOST_PUBLIC_IP" => "203.0.113.54",
          "VPN_SELFHOST_PUBLIC_KEY" => "self-host-public-key-dual",
          "VPN_SELFHOST_LISTEN_PORT" => "51820",
          "VPN_SELFHOST_SS_LISTEN_PORT" => "8388",
          "VPN_SELFHOST_SS_PORT_RANGE_START" => "8388",
          "VPN_SELFHOST_SS_PORT_RANGE_END" => "8400"
        })

      assert length(servers) == 2

      wireguard = Enum.find(servers, &(&1.protocol == "wireguard"))
      shadowsocks = Enum.find(servers, &(&1.protocol == "shadowsocks"))

      assert wireguard.public_ip == "203.0.113.54"
      assert wireguard.endpoint_port == 51_820
      assert shadowsocks.public_ip == "203.0.113.54"
      assert shadowsocks.endpoint_port == 8388
      assert shadowsocks.public_key == "shadowsocks"
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
