defmodule Elektrine.DNS.HealthMonitorTest do
  use ExUnit.Case, async: false

  alias Elektrine.DNS.HealthMonitor

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, open_port} = :inet.port(listener)

    # A port that nothing listens on: bind then close to reserve-and-release.
    {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, closed_port} = :inet.port(probe)
    :gen_tcp.close(probe)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if :ets.whereis(:elektrine_dns_health_status) != :undefined do
        :ets.delete(:elektrine_dns_health_status, {"127.0.0.1", open_port})
        :ets.delete(:elektrine_dns_health_status, {"127.0.0.1", closed_port})
      end
    end)

    %{open_port: open_port, closed_port: closed_port}
  end

  defp start_monitor(targets) do
    name = :"health_monitor_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {HealthMonitor, name: name, interval_ms: :manual, targets_fun: fn -> targets end}
    )

    name
  end

  test "reachable targets are healthy", %{open_port: open_port} do
    monitor = start_monitor([{"127.0.0.1", open_port}])

    HealthMonitor.check_now(monitor)

    assert HealthMonitor.healthy?("127.0.0.1", open_port)
  end

  test "targets go down only after consecutive failures", %{closed_port: closed_port} do
    monitor = start_monitor([{"127.0.0.1", closed_port}])

    HealthMonitor.check_now(monitor)
    assert HealthMonitor.healthy?("127.0.0.1", closed_port)

    HealthMonitor.check_now(monitor)
    refute HealthMonitor.healthy?("127.0.0.1", closed_port)
  end

  test "downed targets recover on first success", %{closed_port: closed_port} do
    monitor = start_monitor([{"127.0.0.1", closed_port}])

    HealthMonitor.check_now(monitor)
    HealthMonitor.check_now(monitor)
    refute HealthMonitor.healthy?("127.0.0.1", closed_port)

    {:ok, revived} =
      :gen_tcp.listen(closed_port, [:binary, active: false, ip: {127, 0, 0, 1}])

    HealthMonitor.check_now(monitor)
    assert HealthMonitor.healthy?("127.0.0.1", closed_port)

    :gen_tcp.close(revived)
  end

  test "unknown targets default to healthy" do
    assert HealthMonitor.healthy?("192.0.2.99", 443)
  end

  test "departed targets are pruned from the table", %{closed_port: closed_port} do
    monitor = start_monitor([{"127.0.0.1", closed_port}])

    HealthMonitor.check_now(monitor)
    HealthMonitor.check_now(monitor)
    refute HealthMonitor.healthy?("127.0.0.1", closed_port)

    empty = :"health_monitor_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {HealthMonitor, name: empty, interval_ms: :manual, targets_fun: fn -> [] end},
      id: :empty_monitor
    )

    HealthMonitor.check_now(empty)

    assert HealthMonitor.healthy?("127.0.0.1", closed_port)
  end
end
