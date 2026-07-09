defmodule Elektrine.VPN.ShadowsocksAdapter do
  @moduledoc false

  @default_config_path "/data/vpn/shadowsocks.json"
  @client_config_prefix "shadowsocks-client-"

  def write_config(snapshot, opts \\ []) do
    config_path = Keyword.get(opts, :config_path, config_path())
    config_dir = config_dir(config_path)
    desired_configs = client_configs(snapshot, opts)

    File.mkdir_p!(config_dir)
    File.mkdir_p!(Path.dirname(config_path))
    remove_stale_client_configs(config_dir, Map.keys(desired_configs))

    Enum.each(desired_configs, fn {port, config} ->
      File.write!(
        client_config_path(config_dir, port),
        Jason.encode_to_iodata!(config, pretty: true)
      )
    end)

    File.write!(
      config_path,
      Jason.encode_to_iodata!(%{"clients" => desired_configs}, pretty: true)
    )

    :ok
  end

  def config_changed?(snapshot, opts \\ []) do
    config_path = Keyword.get(opts, :config_path, config_path())

    desired =
      Jason.encode_to_iodata!(%{"clients" => client_configs(snapshot, opts)}, pretty: true)

    case File.read(config_path) do
      {:ok, existing} -> IO.iodata_to_binary(desired) != existing
      {:error, _reason} -> true
    end
  end

  def start_servers(snapshot, opts \\ []) do
    config_path = Keyword.get(opts, :config_path, config_path())
    config_dir = config_dir(config_path)
    manager_socket = Keyword.get(opts, :manager_socket)

    with {:ok, executable} <- resolve_executable(Keyword.get(opts, :executable, executable())) do
      snapshot.clients
      |> Enum.reject(&is_nil(&1.port))
      |> Enum.reduce_while({:ok, %{}}, fn client, {:ok, ports} ->
        case start_server(executable, client_config_path(config_dir, client.port), manager_socket) do
          {:ok, port} ->
            {:cont, {:ok, Map.put(ports, client.port, port)}}

          {:error, reason} ->
            close_ports(Map.values(ports))
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  def close_ports(ports) do
    Enum.each(ports, fn port ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  rescue
    e in ErlangError -> {:error, {:command_failed, Exception.message(e)}}
  end

  def executable, do: System.get_env("SHADOWSOCKS_SERVER_BIN") || "ss-server"
  def config_path, do: System.get_env("VPN_SELFHOST_SS_CONFIG_PATH") || @default_config_path
  def listen_host, do: System.get_env("VPN_SELFHOST_SS_LISTEN_HOST") || "0.0.0.0"

  @doc """
  Filesystem path of the ss-server manager (stat) socket. Each `ss-server` is
  launched with `--manager-address` pointing here; shadowsocks-libev then pushes
  `stat:` datagrams with per-port cumulative byte totals used for quota accounting.
  """
  def manager_socket_path(opts \\ []) do
    Keyword.get(opts, :manager_socket) ||
      System.get_env("VPN_SELFHOST_SS_MANAGER_SOCKET") ||
      Path.join(config_dir(config_path()), "manager.sock")
  end

  @doc """
  Parses a shadowsocks-libev manager `stat:` datagram into a map of
  `server_port => cumulative_bytes`. Returns `:error` for anything else.

  The wire format is the literal ASCII `stat: {"<port>": <bytes>}`, sometimes
  padded with trailing NUL bytes, so we strip NULs and whitespace before decoding.
  """
  def parse_manager_stat(data) when is_binary(data) do
    trimmed = data |> String.replace(<<0>>, "") |> String.trim()

    case trimmed do
      "stat:" <> json ->
        decode_stat_payload(json)

      _ ->
        :error
    end
  end

  def parse_manager_stat(_data), do: :error

  defp decode_stat_payload(json) do
    case Jason.decode(String.trim(json)) do
      {:ok, map} when is_map(map) ->
        {:ok,
         Enum.reduce(map, %{}, fn
           {port_str, bytes}, acc when is_integer(bytes) ->
             case Integer.parse(to_string(port_str)) do
               {port, ""} -> Map.put(acc, port, bytes)
               _ -> acc
             end

           _entry, acc ->
             acc
         end)}

      _ ->
        :error
    end
  end

  @doc """
  Turns `{port => bytes}` totals plus a `port => client_id` map into peer-stat
  entries for `Elektrine.VPN.report_peer_stats/2`. ss-server reports a single
  combined total per port, so it is carried as `bytes_received` (with
  `bytes_sent` 0); the quota logic only uses the sum.
  """
  def stats_entries(port_totals, port_clients) do
    Enum.flat_map(port_totals, fn {port, bytes} ->
      case Map.get(port_clients, port) do
        nil -> []
        client_id -> [%{"public_key" => client_id, "bytes_sent" => 0, "bytes_received" => bytes}]
      end
    end)
  end

  def resolve_executable(executable) when is_binary(executable) do
    executable = String.trim(executable)

    cond do
      executable == "" or String.contains?(executable, <<0>>) ->
        {:error, :invalid_executable}

      Path.type(executable) == :absolute and File.regular?(executable) ->
        {:ok, executable}

      Path.type(executable) == :absolute ->
        {:error, {:command_failed, "#{executable} executable not found"}}

      String.contains?(executable, "/") ->
        {:error, :invalid_executable}

      resolved = System.find_executable(executable) ->
        {:ok, resolved}

      true ->
        {:error, {:command_failed, "#{executable} executable not found"}}
    end
  end

  def resolve_executable(_executable), do: {:error, :invalid_executable}

  def timeout_seconds do
    case Integer.parse(System.get_env("VPN_SELFHOST_SS_TIMEOUT") || "300") do
      {value, _} -> value
      :error -> 300
    end
  end

  defp client_configs(snapshot, opts) do
    server_host = Keyword.get(opts, :server_host, listen_host())
    timeout = Keyword.get(opts, :timeout, timeout_seconds())

    snapshot.clients
    |> Enum.reject(&is_nil(&1.port))
    |> Map.new(fn client ->
      {to_string(client.port),
       %{
         "server" => server_host,
         "server_port" => client.port,
         "password" => client.password,
         "method" => client.cipher,
         "timeout" => timeout,
         "fast_open" => true
       }}
    end)
  end

  defp start_server(executable, config_path, manager_socket) do
    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: server_args(config_path, manager_socket)
     ])}
  rescue
    e in ErlangError -> {:error, {:command_failed, Exception.message(e)}}
  end

  defp server_args(config_path, nil), do: ["-c", config_path, "-u"]

  defp server_args(config_path, manager_socket),
    do: ["-c", config_path, "-u", "--manager-address", to_string(manager_socket)]

  defp config_dir(config_path), do: Path.rootname(config_path)

  defp client_config_path(config_dir, port) do
    Path.join(config_dir, "#{@client_config_prefix}#{port}.json")
  end

  defp remove_stale_client_configs(config_dir, desired_ports) do
    desired_paths =
      desired_ports
      |> Enum.map(&client_config_path(config_dir, &1))
      |> MapSet.new()

    config_dir
    |> Path.join("#{@client_config_prefix}*.json")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(desired_paths, &1))
    |> Enum.each(&File.rm/1)
  end
end
