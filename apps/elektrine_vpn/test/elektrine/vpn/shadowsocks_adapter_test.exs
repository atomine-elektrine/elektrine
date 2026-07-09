defmodule Elektrine.VPN.ShadowsocksAdapterTest do
  use ExUnit.Case, async: true

  alias Elektrine.VPN.ShadowsocksAdapter

  describe "write_config/2" do
    test "writes libev-compatible per-client configs" do
      config_path = tmp_config_path()

      snapshot = %{
        clients: [
          %{
            port: 8388,
            password: "secret",
            cipher: "chacha20-ietf-poly1305"
          }
        ]
      }

      assert :ok = ShadowsocksAdapter.write_config(snapshot, config_path: config_path)

      client_config =
        config_path
        |> Path.rootname()
        |> Path.join("shadowsocks-client-8388.json")
        |> File.read!()
        |> Jason.decode!()

      assert client_config["server"] == "0.0.0.0"
      assert client_config["server_port"] == 8388
      assert client_config["password"] == "secret"
      assert client_config["method"] == "chacha20-ietf-poly1305"
      refute Map.has_key?(client_config, "port_password")
    end

    test "removes stale client configs" do
      config_path = tmp_config_path()
      config_dir = Path.rootname(config_path)
      File.mkdir_p!(config_dir)
      stale_path = Path.join(config_dir, "shadowsocks-client-9000.json")
      File.write!(stale_path, "{}")

      snapshot = %{clients: [%{port: 8388, password: "secret", cipher: "chacha20-ietf-poly1305"}]}

      assert :ok = ShadowsocksAdapter.write_config(snapshot, config_path: config_path)

      refute File.exists?(stale_path)
      assert File.exists?(Path.join(config_dir, "shadowsocks-client-8388.json"))
    end
  end

  describe "resolve_executable/1" do
    test "resolves bare executable names through the system path" do
      executable = System.find_executable("sh") || System.find_executable("true")

      assert {:ok, ^executable} = ShadowsocksAdapter.resolve_executable(Path.basename(executable))
    end

    test "rejects relative executable paths" do
      assert {:error, :invalid_executable} =
               ShadowsocksAdapter.resolve_executable("./ss-server")

      assert {:error, :invalid_executable} =
               ShadowsocksAdapter.resolve_executable("bin/ss-server")
    end

    test "rejects empty and NUL-containing executable values" do
      assert {:error, :invalid_executable} = ShadowsocksAdapter.resolve_executable("")
      assert {:error, :invalid_executable} = ShadowsocksAdapter.resolve_executable("ss" <> <<0>>)
    end

    test "rejects missing absolute executable paths" do
      assert {:error, {:command_failed, message}} =
               ShadowsocksAdapter.resolve_executable("/definitely/missing/ss-server")

      assert message =~ "executable not found"
    end
  end

  defp tmp_config_path do
    path =
      Path.join([
        System.tmp_dir!(),
        "elektrine-ss-adapter-#{System.unique_integer([:positive])}",
        "shadowsocks.json"
      ])

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    path
  end
end
