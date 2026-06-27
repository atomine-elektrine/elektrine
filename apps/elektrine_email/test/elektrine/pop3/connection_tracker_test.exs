defmodule Elektrine.POP3.ConnectionTrackerTest do
  use ExUnit.Case, async: false

  alias Elektrine.POP3.ConnectionTracker

  setup do
    reset_table(:pop3_active_connections)
    reset_table(:pop3_active_connections_tls)

    on_exit(fn ->
      reset_table(:pop3_active_connections)
      reset_table(:pop3_active_connections_tls)
    end)

    :ok
  end

  test "tracks TCP connection counts and keeps cleanup non-negative" do
    ConnectionTracker.initialize(:tcp)

    assert ConnectionTracker.can_accept?("127.0.0.1", :tcp)

    assert :ok = ConnectionTracker.increment("127.0.0.1", :tcp)
    assert :ets.lookup(:pop3_active_connections, :total) == [{:total, 1}]
    assert :ets.lookup(:pop3_active_connections, "127.0.0.1") == [{"127.0.0.1", 1}]

    assert :ok = ConnectionTracker.decrement("127.0.0.1", :tcp)
    assert :ets.lookup(:pop3_active_connections, :total) == [{:total, 0}]
    assert :ets.lookup(:pop3_active_connections, "127.0.0.1") == []

    assert :ok = ConnectionTracker.decrement("127.0.0.1", :tcp)
    assert :ets.lookup(:pop3_active_connections, :total) == [{:total, 0}]
  end

  test "tracks TLS handshake reservations separately from established sessions" do
    ConnectionTracker.initialize(:ssl)

    assert :ok = ConnectionTracker.reserve_handshake_slot("127.0.0.1", :ssl)
    assert :ets.lookup(:pop3_active_connections_tls, :total) == [{:total, 0}]
    assert :ets.lookup(:pop3_active_connections_tls, :pending_total) == [{:pending_total, 1}]

    assert :ok = ConnectionTracker.release_handshake_slot("127.0.0.1", :ssl)
    assert :ets.lookup(:pop3_active_connections_tls, :pending_total) == [{:pending_total, 0}]
    assert :ets.lookup(:pop3_active_connections_tls, {:pending, "127.0.0.1"}) == []
  end

  test "cleanup is a no-op when the server table is already gone" do
    assert :ok = ConnectionTracker.decrement("127.0.0.1", :tcp)
    assert :ok = ConnectionTracker.release_handshake_slot("127.0.0.1", :ssl)
  end

  defp reset_table(table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete(table)
    end
  end
end
