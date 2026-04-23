defmodule Elektrine.IMAP.Server do
  @moduledoc """
  IMAP server implementation for Elektrine email system.
  Provides IMAP4rev1 protocol support for email clients.

  This module handles GenServer lifecycle, TCP connection management,
  and delegates command processing to specialized modules.
  """

  use GenServer
  require Logger
  alias Elektrine.Constants
  alias Elektrine.IMAP.{Commands, Helpers}
  alias Elektrine.IMAP.RecentTracker
  alias Elektrine.Mail.Socket
  alias Elektrine.Mail.Telemetry, as: MailTelemetry
  alias Elektrine.ProxyProtocol

  # Security limits
  @max_connections Constants.imap_max_connections()
  @max_connections_per_ip Constants.imap_max_connections_per_ip()
  @connection_timeout_ms Constants.imap_connection_timeout_ms()
  @inactivity_timeout_ms Constants.imap_inactivity_timeout_ms()
  @idle_cleanup_interval_ms 5 * 60 * 1000
  @idle_stale_grace_ms 60_000
  @slow_command_threshold_us 500_000

  # GenServer callbacks

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:elektrine, :imap_port, 2143))
    transport = Keyword.get(opts, :transport, :tcp)
    tls_opts = Keyword.get(opts, :tls_opts, [])

    allow_insecure_auth =
      Keyword.get(
        opts,
        :allow_insecure_auth,
        Application.get_env(:elektrine, :allow_insecure_mail_auth, false)
      )

    case Socket.listen(
           transport,
           port,
           [
             {:active, false},
             {:packet, :line},
             {:packet_size, 8192},
             {:reuseaddr, true},
             {:ip, {0, 0, 0, 0}},
             {:backlog, 100},
             {:keepalive, true},
             {:send_timeout, Constants.imap_send_timeout_ms()},
             {:send_timeout_close, true}
           ],
           tls_opts
         ) do
      {:ok, socket} ->
        idle_table = idle_table_name(transport)
        invalid_table = invalid_table_name(transport)
        active_table = active_table_name(transport)

        # Create ETS tables for connection tracking and honeypot detection
        ensure_table(idle_table)
        ensure_table(invalid_table)
        ensure_table(active_table)
        RecentTracker.table()
        :ets.insert(active_table, {:total, 0})

        # Start periodic cleanup task for stale IDLE connections
        spawn_link(fn -> periodic_idle_cleanup(transport) end)

        spawn_link(fn -> accept_loop(socket, transport, tls_opts, allow_insecure_auth) end)

        {:ok,
         %{
           socket: socket,
           port: port,
           transport: transport,
           connections: 0,
           connections_per_ip: %{},
           allow_insecure_auth: allow_insecure_auth
         }}

      {:error, :eaddrinuse} ->
        Logger.error("IMAP server failed: Port #{port} is already in use")

        {:ok,
         %{
           socket: nil,
           port: port,
           transport: transport,
           connections: 0,
           connections_per_ip: %{},
           error: :port_in_use
         }}

      {:error, reason} ->
        Logger.error("Failed to start IMAP server on port #{port}: #{inspect(reason)}")

        {:ok,
         %{
           socket: nil,
           port: port,
           transport: transport,
           connections: 0,
           connections_per_ip: %{},
           error: reason
         }}
    end
  end

  # Connection handling

  defp accept_loop(socket, transport, tls_opts, allow_insecure_auth) do
    case Socket.accept(transport, socket) do
      {:ok, client} ->
        handle_accepted_client(client, transport, tls_opts, allow_insecure_auth)
        accept_loop(socket, transport, tls_opts, allow_insecure_auth)

      {:error, reason} ->
        Logger.error("Accept failed: #{inspect(reason)}")
        :timer.sleep(1000)
        accept_loop(socket, transport, tls_opts, allow_insecure_auth)
    end
  end

  defp handle_accepted_client(client, :ssl, tls_opts, allow_insecure_auth) do
    spawn(fn ->
      case Socket.handshake(client) do
        {:ok, tls_client} ->
          handle_authenticated_client(tls_client, :ssl, tls_opts, allow_insecure_auth)

        _ ->
          :ok
      end
    end)
  end

  defp handle_accepted_client(client, transport, tls_opts, allow_insecure_auth) do
    handle_authenticated_client(client, transport, tls_opts, allow_insecure_auth)
  end

  defp handle_authenticated_client(client, transport, tls_opts, allow_insecure_auth) do
    {client_ip, initial_data} = client_ip_and_data(client, transport)

    cond do
      is_nil(client_ip) ->
        :ok

      !can_accept_connection?(client_ip, transport) ->
        Logger.warning("Connection rejected from #{client_ip}: connection limit exceeded")
        Helpers.send_response(client, "* BYE Too many connections from your IP address")
        Socket.close(client)

      true ->
        Socket.setopts(client, [
          {:active, false},
          {:packet, :line},
          {:keepalive, true},
          {:nodelay, true},
          {:send_timeout, Constants.imap_send_timeout_ms()},
          {:recbuf, 65_536},
          {:sndbuf, 65_536}
        ])

        increment_connection_count(client_ip, transport)

        handler_pid =
          spawn(fn ->
            receive do
              :go -> :ok
            end

            Process.put(:imap_socket_transport, transport)

            try do
              handle_client(client, client_ip, initial_data, tls_opts, allow_insecure_auth)
            after
              decrement_connection_count(client_ip, transport)
            end
          end)

        case Socket.controlling_process(client, handler_pid) do
          :ok ->
            send(handler_pid, :go)

          {:error, reason} ->
            Logger.error("IMAP failed to transfer socket ownership: #{inspect(reason)}")
            Socket.close(client)
            decrement_connection_count(client_ip, transport)
        end
    end
  end

  defp client_ip_and_data(client, :ssl) do
    case Socket.peername(client) do
      {:ok, {ip, _port}} ->
        {:inet.ntoa(ip) |> to_string(), nil}

      {:error, _} ->
        Socket.close(client)
        {nil, nil}
    end
  end

  defp client_ip_and_data(client, :tcp) do
    case ProxyProtocol.parse_client_ip(client) do
      {:ok, ip, data} ->
        {ip, data}

      {:error, _reason} ->
        case Socket.peername(client) do
          {:ok, {ip, _port}} ->
            ip_string = :inet.ntoa(ip) |> to_string()
            Socket.close(client)
            {ip_string, nil}

          {:error, _} ->
            Socket.close(client)
            {nil, nil}
        end
    end
  end

  defp handle_client(socket, client_ip, initial_data, tls_opts, allow_insecure_auth) do
    # Send greeting with CAPABILITY to help clients detect features early
    Helpers.send_response(
      socket,
      "* OK [CAPABILITY #{Commands.capability_string(%{state: :not_authenticated, socket: socket, transport: socket_transport(), tls_opts: tls_opts})}] Elektrine IMAP4rev1 server ready"
    )

    # Normalize IPv6 subnet if needed
    normalized_ip = Helpers.normalize_ipv6_subnet(client_ip)

    now = System.monotonic_time(:millisecond)

    state = %{
      socket: socket,
      client_ip: normalized_ip,
      authenticated: false,
      user: nil,
      username: nil,
      mailbox: nil,
      selected_folder: nil,
      messages: [],
      uid_validity: 1,
      state: :not_authenticated,
      transport: socket_transport(),
      message_flags: %{},
      recent_message_ids: MapSet.new(),
      folder_key: nil,
      idle_session_id: nil,
      connection_start: now,
      last_activity: now,
      idle_start: nil,
      initial_data: initial_data,
      tls_opts: tls_opts,
      allow_insecure_auth: allow_insecure_auth
    }

    # Use Process dictionary to track IDLE session for cleanup
    # This allows cleanup even if the process crashes
    Process.put(:imap_client_ip, normalized_ip)

    # Ensure cleanup happens when connection ends
    try do
      client_loop(state)
    after
      # Clean up any lingering IDLE sessions for this IP
      # Check Process dictionary for session_id that might be set during IDLE
      case Process.get(:imap_idle_session_id) do
        nil ->
          :ok

        session_id ->
          cleanup_idle_session(normalized_ip, session_id)
      end
    end
  end

  defp cleanup_idle_session(ip, session_id) do
    table = idle_table_name(socket_transport())

    if :ets.whereis(table) != :undefined do
      case :ets.lookup(table, ip) do
        [{^ip, sessions}] ->
          new_sessions =
            sessions
            |> normalize_idle_sessions(System.monotonic_time(:millisecond))
            |> Enum.reject(fn {existing_session_id, _started_at} ->
              existing_session_id == session_id
            end)

          if new_sessions == [] do
            :ets.delete(table, ip)
          else
            :ets.insert(table, {ip, new_sessions})
          end

        [] ->
          :ok
      end
    end
  end

  defp client_loop(state) do
    now = System.monotonic_time(:millisecond)

    cond do
      # Check total connection timeout (1 hour)
      now - state.connection_start > @connection_timeout_ms ->
        Helpers.send_response(state.socket, "* BYE Connection time limit exceeded")
        Socket.close(state.socket)

      # Check inactivity timeout (15 minutes)
      now - state.last_activity > @inactivity_timeout_ms ->
        Helpers.send_response(state.socket, "* BYE Inactivity timeout")
        Socket.close(state.socket)

      true ->
        # If we have initial_data from PROXY protocol parsing, use it first
        {command_data, updated_state} =
          if state.initial_data do
            {state.initial_data, %{state | initial_data: nil}}
          else
            # Use shorter timeout (5 minutes) for recv to allow periodic timeout checks
            case Socket.recv(state.socket, 0, 300_000) do
              {:ok, data} ->
                {data, state}

              {:error, :timeout} ->
                # recv timeout - loop back to check overall timeouts
                client_loop(state)
                {nil, state}

              {:error, :closed} ->
                Socket.close(state.socket)
                {nil, state}

              {:error, reason} ->
                Logger.error("IMAP receive error: #{inspect(reason)}")
                Socket.close(state.socket)
                {nil, state}
            end
          end

        if command_data do
          command = command_data |> to_string() |> String.trim()
          updated_state = %{updated_state | last_activity: now}

          case handle_command(command, updated_state) do
            {:continue, new_state} ->
              client_loop(new_state)

            {:logout, _new_state} ->
              Socket.close(state.socket)
          end
        end
    end
  end

  defp handle_command(command, state) do
    started_at = System.monotonic_time(:microsecond)

    {command_name, result} =
      case String.split(command, " ", parts: 3) do
        [tag, cmd | rest] ->
          normalized_cmd = String.upcase(cmd)
          args = if rest == [], do: nil, else: List.first(rest)
          {normalized_cmd, Commands.process_command(tag, normalized_cmd, args, state)}

        _ ->
          Helpers.send_response(state.socket, "* BAD Invalid command format")
          {"INVALID", {:continue, state}}
      end

    duration_us = System.monotonic_time(:microsecond) - started_at
    outcome = command_outcome(result)
    MailTelemetry.command(:imap, command_name, duration_us, outcome)
    maybe_alert_slow_command(command_name, duration_us, state.client_ip)

    result
  end

  # Connection limit enforcement

  defp can_accept_connection?(ip, transport) do
    table = active_table_name(transport)

    # Check if table exists before checking connection limits
    if :ets.whereis(table) == :undefined do
      # Table doesn't exist - probably during server startup/shutdown
      Logger.warning(
        "IMAP connection count table does not exist, rejecting connection from #{ip}"
      )

      false
    else
      total =
        case :ets.lookup(table, :total) do
          [{:total, count}] -> count
          [] -> 0
        end

      if total >= @max_connections do
        false
      else
        ip_count =
          case :ets.lookup(table, ip) do
            [{^ip, count}] -> count
            [] -> 0
          end

        ip_count < @max_connections_per_ip
      end
    end
  end

  defp increment_connection_count(ip, transport) do
    table = active_table_name(transport)

    # Check if table exists before trying to update it
    if :ets.whereis(table) != :undefined do
      :ets.update_counter(table, :total, {2, 1})

      case :ets.lookup(table, ip) do
        [{^ip, count}] ->
          :ets.insert(table, {ip, count + 1})

        [] ->
          :ets.insert(table, {ip, 1})
      end

      emit_session_count(ip, transport)
    else
      Logger.warning("IMAP connection count table does not exist, skipping increment for #{ip}")
    end
  end

  defp decrement_connection_count(ip, transport) do
    table = active_table_name(transport)

    # Check if table exists before trying to update it
    if :ets.whereis(table) != :undefined do
      :ets.update_counter(table, :total, {2, -1})

      case :ets.lookup(table, ip) do
        [{^ip, count}] when count > 1 ->
          :ets.insert(table, {ip, count - 1})

        [{^ip, 1}] ->
          :ets.delete(table, ip)

        [] ->
          :ok
      end

      emit_session_count(ip, transport)
    end
  end

  defp emit_session_count(ip, transport) do
    table = active_table_name(transport)

    total =
      case :ets.lookup(table, :total) do
        [{:total, count}] -> count
        [] -> 0
      end

    ip_count =
      case :ets.lookup(table, ip) do
        [{^ip, count}] -> count
        [] -> 0
      end

    MailTelemetry.sessions(:imap, total, ip_count)
    maybe_alert_session_pressure(total, ip_count, ip)
  end

  defp maybe_alert_session_pressure(total, ip_count, ip) do
    total_threshold = max(1, div(@max_connections * 8, 10))
    ip_threshold = max(1, div(@max_connections_per_ip * 8, 10))

    cond do
      total >= total_threshold ->
        Logger.warning(
          "IMAP connection pressure: total=#{total}/#{@max_connections} ip=#{ip} ip_sessions=#{ip_count}/#{@max_connections_per_ip}"
        )

      ip_count >= ip_threshold ->
        Logger.warning(
          "IMAP per-IP session pressure: ip=#{ip} sessions=#{ip_count}/#{@max_connections_per_ip} total=#{total}/#{@max_connections}"
        )

      true ->
        :ok
    end
  end

  defp command_outcome({:continue, _state}), do: :ok
  defp command_outcome({:logout, _state}), do: :logout
  defp command_outcome(_), do: :error

  defp maybe_alert_slow_command(command_name, duration_us, ip) do
    if duration_us >= @slow_command_threshold_us do
      duration_ms = Float.round(duration_us / 1_000, 1)

      Logger.warning(
        "Slow IMAP command: command=#{command_name} duration_ms=#{duration_ms} ip=#{ip}"
      )
    end
  end

  # Periodic cleanup of stale IDLE connections
  defp periodic_idle_cleanup(transport) do
    :timer.sleep(@idle_cleanup_interval_ms)

    table = idle_table_name(transport)

    if :ets.whereis(table) != :undefined do
      prune_stale_idle_connections(table)
    end

    periodic_idle_cleanup(transport)
  end

  defp prune_stale_idle_connections(table) do
    now = System.monotonic_time(:millisecond)
    stale_cutoff = now - Constants.imap_idle_timeout_ms() - @idle_stale_grace_ms

    :ets.foldl(
      fn {ip, sessions}, _acc ->
        active_sessions =
          sessions
          |> normalize_idle_sessions(now)
          |> Enum.reject(fn {_session_id, started_at} ->
            started_at < stale_cutoff
          end)

        if active_sessions == [] do
          :ets.delete(table, ip)
        else
          :ets.insert(table, {ip, active_sessions})
        end

        nil
      end,
      nil,
      table
    )
  end

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table])
    end
  end

  defp socket_transport do
    case Process.get(:imap_socket_transport) do
      transport when transport in [:tcp, :ssl] -> transport
      _ -> :tcp
    end
  end

  defp idle_table_name(:ssl), do: :imap_idle_connections_tls
  defp idle_table_name(_), do: :imap_idle_connections

  defp invalid_table_name(:ssl), do: :imap_invalid_commands_tls
  defp invalid_table_name(_), do: :imap_invalid_commands

  defp active_table_name(:ssl), do: :imap_active_connections_tls
  defp active_table_name(_), do: :imap_active_connections

  defp normalize_idle_sessions(sessions, now) do
    Enum.map(sessions, fn
      {session_id, started_at} when is_integer(started_at) ->
        {session_id, started_at}

      session_id ->
        {session_id, now}
    end)
  end
end
