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

    with {:ok, executable} <- resolve_executable(Keyword.get(opts, :executable, executable())) do
      snapshot.clients
      |> Enum.reject(&is_nil(&1.port))
      |> Enum.reduce_while({:ok, %{}}, fn client, {:ok, ports} ->
        case start_server(executable, client_config_path(config_dir, client.port)) do
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

  defp start_server(executable, config_path) do
    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: ["-c", config_path, "-u"]
     ])}
  rescue
    e in ErlangError -> {:error, {:command_failed, Exception.message(e)}}
  end

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
