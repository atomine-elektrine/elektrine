defmodule Elektrine.VPN.ShadowsocksAdapter do
  @moduledoc false

  @default_config_path "/data/vpn/shadowsocks.json"

  def write_config(snapshot, opts \\ []) do
    config_path = Keyword.get(opts, :config_path, config_path())

    config = %{
      "server" => Keyword.get(opts, :server_host, listen_host()),
      "fast_open" => true,
      "mode" => "tcp_and_udp",
      "timeout" => Keyword.get(opts, :timeout, timeout_seconds()),
      "port_password" => port_passwords(snapshot.clients)
    }

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, Jason.encode_to_iodata!(config, pretty: true))
    :ok
  end

  def config_changed?(snapshot, opts \\ []) do
    config_path = Keyword.get(opts, :config_path, config_path())

    desired =
      Jason.encode_to_iodata!(
        %{
          "server" => Keyword.get(opts, :server_host, listen_host()),
          "fast_open" => true,
          "mode" => "tcp_and_udp",
          "timeout" => Keyword.get(opts, :timeout, timeout_seconds()),
          "port_password" => port_passwords(snapshot.clients)
        },
        pretty: true
      )

    case File.read(config_path) do
      {:ok, existing} -> IO.iodata_to_binary(desired) != existing
      {:error, _reason} -> true
    end
  end

  def start_server(opts \\ []) do
    Port.open({:spawn_executable, Keyword.get(opts, :executable, executable())}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["-c", Keyword.get(opts, :config_path, config_path())]
    ])
  end

  def executable, do: System.get_env("SHADOWSOCKS_SERVER_BIN") || "ss-server"
  def config_path, do: System.get_env("VPN_SELFHOST_SS_CONFIG_PATH") || @default_config_path
  def listen_host, do: System.get_env("VPN_SELFHOST_SS_LISTEN_HOST") || "0.0.0.0"

  def timeout_seconds do
    case Integer.parse(System.get_env("VPN_SELFHOST_SS_TIMEOUT") || "300") do
      {value, _} -> value
      :error -> 300
    end
  end

  defp port_passwords(clients) do
    Enum.reduce(clients, %{}, fn client, acc ->
      Map.put(acc, to_string(client.port), client.password)
    end)
  end
end
