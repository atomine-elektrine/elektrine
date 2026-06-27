defmodule Elektrine.POP3.ConnectionTracker do
  @moduledoc false

  require Logger
  alias Elektrine.Constants
  alias Elektrine.Mail.Telemetry, as: MailTelemetry

  def initialize(transport) do
    table = active_table_name(transport)
    ensure_table(table)
    :ets.insert(table, {:total, 0})
    :ok
  end

  def can_accept?(ip, transport) do
    table = active_table_name(transport)
    ensure_table(table)

    lookup_count(table, :total) < max_connections() and
      lookup_count(table, ip) < max_connections_per_ip()
  end

  def reserve_handshake_slot(ip, transport) do
    table = active_table_name(transport)

    if table_exists?(table) do
      pending_total = :ets.update_counter(table, :pending_total, {2, 1}, {:pending_total, 0})
      ip_key = {:pending, ip}
      ip_pending = :ets.update_counter(table, ip_key, {2, 1}, {ip_key, 0})

      if pending_total > max_connections() or ip_pending > max_connections_per_ip() do
        release_handshake_slot(ip, transport)
        :error
      else
        :ok
      end
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  def release_handshake_slot(ip, transport) do
    table = active_table_name(transport)

    if table_exists?(table) do
      decrement_counter(table, :pending_total)
      ip_key = {:pending, ip}

      if decrement_counter(table, ip_key) == 0 do
        :ets.delete(table, ip_key)
      end
    end

    :ok
  end

  def increment(ip, transport) do
    table = active_table_name(transport)
    ensure_table(table)

    :ets.update_counter(table, :total, {2, 1}, {:total, 0})
    :ets.update_counter(table, ip, {2, 1}, {ip, 0})
    emit_session_count(ip, transport)
  rescue
    ArgumentError -> :ok
  end

  def decrement(ip, transport) do
    table = active_table_name(transport)

    if table_exists?(table) do
      decrement_count(table, :total)
      decrement_count(table, ip)
      emit_session_count(ip, transport)
    else
      :ok
    end
  end

  defp decrement_count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, count}] when count > 1 ->
        :ets.insert(table, {key, count - 1})
        count - 1

      [{^key, _count}] ->
        if key == :total do
          :ets.insert(table, {:total, 0})
        else
          :ets.delete(table, key)
        end

        0

      [] ->
        0
    end
  rescue
    ArgumentError -> 0
  end

  defp decrement_counter(table, key) do
    :ets.update_counter(table, key, {2, -1, 0, 0}, {key, 0})
  rescue
    ArgumentError -> 0
  end

  defp emit_session_count(ip, transport) do
    table = active_table_name(transport)

    if table_exists?(table) do
      total = lookup_count(table, :total)
      ip_count = lookup_count(table, ip)

      MailTelemetry.sessions(:pop3, total, ip_count)
      maybe_alert_session_pressure(total, ip_count, ip)
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp maybe_alert_session_pressure(total, ip_count, ip) do
    max_connections = max_connections()
    max_connections_per_ip = max_connections_per_ip()
    total_threshold = max(1, div(max_connections * 8, 10))
    ip_threshold = max(1, div(max_connections_per_ip * 8, 10))

    cond do
      total >= total_threshold ->
        Logger.warning(
          "POP3 connection pressure: total=#{total}/#{max_connections} ip=#{ip} ip_sessions=#{ip_count}/#{max_connections_per_ip}"
        )

      ip_count >= ip_threshold ->
        Logger.warning(
          "POP3 per-IP session pressure: ip=#{ip} sessions=#{ip_count}/#{max_connections_per_ip} total=#{total}/#{max_connections}"
        )

      true ->
        :ok
    end
  end

  defp lookup_count(table, key) do
    case :ets.lookup(table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp ensure_table(table) do
    if not table_exists?(table) do
      :ets.new(table, [:set, :public, :named_table])
    end
  rescue
    ArgumentError -> :ok
  end

  defp table_exists?(table), do: :ets.whereis(table) != :undefined

  defp max_connections, do: Constants.pop3_max_connections()
  defp max_connections_per_ip, do: Constants.pop3_max_connections_per_ip()

  defp active_table_name(:ssl), do: :pop3_active_connections_tls
  defp active_table_name(_transport), do: :pop3_active_connections
end
