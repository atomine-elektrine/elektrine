defmodule Elektrine.IMAP.IdleTracker do
  @moduledoc false

  require Logger

  alias Elektrine.Constants

  @idle_stale_grace_ms 60_000

  def count_connections(state) do
    table = idle_table_name(state)

    if :ets.whereis(table) != :undefined do
      case :ets.lookup(table, state.client_ip) do
        [{ip, sessions}] when ip == state.client_ip ->
          active_sessions = persist_active_idle_sessions(table, state.client_ip, sessions)
          length(active_sessions)

        [] ->
          0
      end
    else
      0
    end
  end

  def track_connection(state, ip, session_id) do
    table = idle_table_name(state)

    if :ets.whereis(table) != :undefined do
      now = System.monotonic_time(:millisecond)

      sessions =
        case :ets.lookup(table, ip) do
          [{^ip, existing}] ->
            existing
            |> normalize_idle_sessions(now)
            |> Enum.reject(fn {existing_session_id, _started_at} ->
              existing_session_id == session_id
            end)
            |> then(&[{session_id, now} | &1])

          [] ->
            [{session_id, now}]
        end

      :ets.insert(table, {ip, sessions})
    end
  end

  def untrack_connection(state, ip, session_id) do
    table = idle_table_name(state)

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

  def track_invalid_command(state, ip, _command) do
    table = invalid_table_name(state)

    if :ets.whereis(table) != :undefined do
      now = System.system_time(:second)
      table_size = :ets.info(table, :size)
      max_tracked_ips = 10_000

      if table_size >= max_tracked_ips do
        cleanup_old_invalid_command_entries(table, now)
      end

      {count, first_seen} =
        case :ets.lookup(table, ip) do
          [{^ip, c, t}] -> {c + 1, t}
          [] -> {1, now}
        end

      :ets.insert(table, {ip, count, first_seen})

      if count >= 5 do
        Logger.error(
          "SECURITY ALERT: Possible port scanner detected from #{ip} - #{count} invalid commands in #{now - first_seen}s"
        )
      end

      count
    else
      0
    end
  end

  defp persist_active_idle_sessions(table, ip, sessions) do
    now = System.monotonic_time(:millisecond)

    active_sessions =
      sessions
      |> normalize_idle_sessions(now)
      |> Enum.reject(fn {_session_id, started_at} ->
        now - started_at > Constants.imap_idle_timeout_ms() + @idle_stale_grace_ms
      end)

    if active_sessions == [] do
      :ets.delete(table, ip)
    else
      :ets.insert(table, {ip, active_sessions})
    end

    active_sessions
  end

  defp normalize_idle_sessions(sessions, now) do
    Enum.map(sessions, fn
      {session_id, started_at} when is_integer(started_at) -> {session_id, started_at}
      session_id -> {session_id, now}
    end)
  end

  defp cleanup_old_invalid_command_entries(table, now) do
    if :ets.whereis(table) != :undefined do
      cutoff = now - 3600

      :ets.foldl(
        fn {ip, _count, first_seen}, acc ->
          if first_seen < cutoff do
            :ets.delete(table, ip)
          end

          acc
        end,
        nil,
        table
      )
    end
  end

  defp idle_table_name(%{transport: :ssl}), do: :imap_idle_connections_tls
  defp idle_table_name(_state), do: :imap_idle_connections

  defp invalid_table_name(%{transport: :ssl}), do: :imap_invalid_commands_tls
  defp invalid_table_name(_state), do: :imap_invalid_commands
end
