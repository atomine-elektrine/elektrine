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
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:elektrine, :imap_port, 2143))

    case :gen_tcp.listen(port, [
           {:active, false},
           {:packet, :line},
           {:packet_size, 8192},
           {:reuseaddr, true},
           {:ip, {0, 0, 0, 0}},
           {:backlog, 100},
           {:keepalive, true},
           {:send_timeout, Constants.imap_send_timeout_ms()},
           {:send_timeout_close, true}
         ]) do
      {:ok, socket} ->
        # Create ETS tables for connection tracking and honeypot detection
        :ets.new(:imap_idle_connections, [:set, :public, :named_table])
        :ets.new(:imap_invalid_commands, [:set, :public, :named_table])
        :ets.new(:imap_active_connections, [:set, :public, :named_table])
        :ets.insert(:imap_active_connections, {:total, 0})

        # Start periodic cleanup task for stale IDLE connections
        spawn_link(fn -> periodic_idle_cleanup() end)

        spawn_link(fn -> accept_loop(socket) end)

        {:ok,
         %{
           socket: socket,
           port: port,
           connections: 0,
           connections_per_ip: %{}
         }}

      {:error, :eaddrinuse} ->
        Logger.error("IMAP server failed: Port #{port} is already in use")

        {:ok,
         %{socket: nil, port: port, connections: 0, connections_per_ip: %{}, error: :port_in_use}}

      {:error, reason} ->
        Logger.error("Failed to start IMAP server on port #{port}: #{inspect(reason)}")
        {:ok, %{socket: nil, port: port, connections: 0, connections_per_ip: %{}, error: reason}}
    end
  end

  # Connection handling

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        # Parse PROXY protocol to get real client IP (Fly.io support)
        {client_ip, initial_data} =
          case ProxyProtocol.parse_client_ip(client) do
            {:ok, ip, data} ->
              {ip, data}

            {:error, _reason} ->
              # Failed to read PROXY protocol, try to get peer IP as fallback
              case :inet.peername(client) do
                {:ok, {ip, _port}} ->
                  ip_string = :inet.ntoa(ip) |> to_string()
                  :gen_tcp.close(client)
                  {ip_string, nil}

                {:error, _} ->
                  # Connection already closed, skip this client
                  :gen_tcp.close(client)
                  {nil, nil}
              end
          end

        cond do
          # Connection already closed during PROXY parsing
          is_nil(client_ip) ->
            # Skip and continue accepting
            :ok

          # Connection limit exceeded
          !can_accept_connection?(client_ip) ->
            Logger.warning("Connection rejected from #{client_ip}: connection limit exceeded")
            Helpers.send_response(client, "* BYE Too many connections from your IP address")
            :gen_tcp.close(client)

          # Accept the connection
          true ->
            :inet.setopts(client, [
              {:keepalive, true},
              {:nodelay, true},
              {:send_timeout, Constants.imap_send_timeout_ms()},
              {:recbuf, 65_536},
              {:sndbuf, 65_536}
            ])

            increment_connection_count(client_ip)

            spawn(fn ->
              try do
                handle_client(client, client_ip, initial_data)
              after
                decrement_connection_count(client_ip)
              end
            end)
        end

        accept_loop(socket)

      {:error, reason} ->
        Logger.error("Accept failed: #{inspect(reason)}")
        :timer.sleep(1000)
        accept_loop(socket)
    end
  end

  defp handle_client(socket, client_ip, initial_data) do
    # Send greeting with CAPABILITY to help clients detect features early
    Helpers.send_response(
      socket,
      "* OK [CAPABILITY #{Commands.capability_string(:not_authenticated)}] Elektrine IMAP4rev1 server ready"
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
      message_flags: %{},
      idle_session_id: nil,
      connection_start: now,
      last_activity: now,
      idle_start: nil,
      initial_data: initial_data
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
    if :ets.whereis(:imap_idle_connections) != :undefined do
      case :ets.lookup(:imap_idle_connections, ip) do
        [{^ip, sessions}] ->
          new_sessions =
            sessions
            |> normalize_idle_sessions(System.monotonic_time(:millisecond))
            |> Enum.reject(fn {existing_session_id, _started_at} ->
              existing_session_id == session_id
            end)

          if new_sessions == [] do
            :ets.delete(:imap_idle_connections, ip)
          else
            :ets.insert(:imap_idle_connections, {ip, new_sessions})
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
        :gen_tcp.close(state.socket)

      # Check inactivity timeout (15 minutes)
      now - state.last_activity > @inactivity_timeout_ms ->
        Helpers.send_response(state.socket, "* BYE Inactivity timeout")
        :gen_tcp.close(state.socket)

      true ->
        # If we have initial_data from PROXY protocol parsing, use it first
        {command_data, updated_state} =
          if state.initial_data do
            {state.initial_data, %{state | initial_data: nil}}
          else
            # Use shorter timeout (5 minutes) for recv to allow periodic timeout checks
            case :gen_tcp.recv(state.socket, 0, 300_000) do
              {:ok, data} ->
                {data, state}

              {:error, :timeout} ->
                # recv timeout - loop back to check overall timeouts
                client_loop(state)
                {nil, state}

              {:error, :closed} ->
                :gen_tcp.close(state.socket)
                {nil, state}

              {:error, reason} ->
                Logger.error("IMAP receive error: #{inspect(reason)}")
                :gen_tcp.close(state.socket)
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
              :gen_tcp.close(state.socket)
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

  defp can_accept_connection?(ip) do
    # Check if table exists before checking connection limits
    if :ets.whereis(:imap_active_connections) == :undefined do
      # Table doesn't exist - probably during server startup/shutdown
      Logger.warning(
        "IMAP connection count table does not exist, rejecting connection from #{ip}"
      )

      false
    else
      total =
        case :ets.lookup(:imap_active_connections, :total) do
          [{:total, count}] -> count
          [] -> 0
        end

      if total >= @max_connections do
        false
      else
        ip_count =
          case :ets.lookup(:imap_active_connections, ip) do
            [{^ip, count}] -> count
            [] -> 0
          end

        ip_count < @max_connections_per_ip
      end
    end
  end

  defp increment_connection_count(ip) do
    # Check if table exists before trying to update it
    if :ets.whereis(:imap_active_connections) != :undefined do
      :ets.update_counter(:imap_active_connections, :total, {2, 1})

      case :ets.lookup(:imap_active_connections, ip) do
        [{^ip, count}] ->
          :ets.insert(:imap_active_connections, {ip, count + 1})

        [] ->
          :ets.insert(:imap_active_connections, {ip, 1})
      end

      emit_session_count(ip)
    else
      Logger.warning("IMAP connection count table does not exist, skipping increment for #{ip}")
    end
  end

  defp decrement_connection_count(ip) do
    # Check if table exists before trying to update it
    if :ets.whereis(:imap_active_connections) != :undefined do
      :ets.update_counter(:imap_active_connections, :total, {2, -1})

      case :ets.lookup(:imap_active_connections, ip) do
        [{^ip, count}] when count > 1 ->
          :ets.insert(:imap_active_connections, {ip, count - 1})

        [{^ip, 1}] ->
          :ets.delete(:imap_active_connections, ip)

        [] ->
          :ok
      end

      emit_session_count(ip)
    end
  end

  defp emit_session_count(ip) do
    total =
      case :ets.lookup(:imap_active_connections, :total) do
        [{:total, count}] -> count
        [] -> 0
      end

    ip_count =
      case :ets.lookup(:imap_active_connections, ip) do
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
  defp periodic_idle_cleanup do
    :timer.sleep(@idle_cleanup_interval_ms)

    if :ets.whereis(:imap_idle_connections) != :undefined do
      prune_stale_idle_connections()
    end

    periodic_idle_cleanup()
  end

  defp prune_stale_idle_connections do
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
          :ets.delete(:imap_idle_connections, ip)
        else
          :ets.insert(:imap_idle_connections, {ip, active_sessions})
        end

        nil
      end,
      nil,
      :imap_idle_connections
    )
  end

  defp normalize_idle_sessions(sessions, now) do
    Enum.map(sessions, fn
      {session_id, started_at} when is_integer(started_at) ->
        {session_id, started_at}

      session_id ->
        {session_id, now}
    end)
  end
end
