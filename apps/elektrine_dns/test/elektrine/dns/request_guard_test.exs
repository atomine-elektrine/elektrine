defmodule Elektrine.DNS.RequestGuardTest do
  use ExUnit.Case, async: false

  alias Elektrine.DNS.RequestGuard

  setup do
    old_dns = Application.get_env(:elektrine, :dns, [])

    clear_table(Elektrine.DNS.RequestGuard)

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, old_dns)
      clear_table(Elektrine.DNS.RequestGuard)
    end)

    :ok
  end

  test "rate limits repeated udp requests from the same client" do
    put_dns_config(
      udp_rate_limit_per_window: 2,
      udp_max_inflight: 10,
      rate_limit_window_ms: 1_000
    )

    assert {:ok, :udp} = RequestGuard.begin_request({127, 0, 0, 1}, :udp)
    RequestGuard.finish_request(:udp)

    assert {:ok, :udp} = RequestGuard.begin_request({127, 0, 0, 1}, :udp)
    RequestGuard.finish_request(:udp)

    assert {:error, :rate_limited} = RequestGuard.begin_request({127, 0, 0, 1}, :udp)
  end

  test "caps concurrent tcp work" do
    put_dns_config(
      tcp_rate_limit_per_window: 10,
      tcp_max_inflight: 1,
      rate_limit_window_ms: 1_000
    )

    assert {:ok, :tcp} = RequestGuard.begin_request({127, 0, 0, 1}, :tcp)
    assert {:error, :busy} = RequestGuard.begin_request({127, 0, 0, 2}, :tcp)

    RequestGuard.finish_request(:tcp)

    assert {:ok, :tcp} = RequestGuard.begin_request({127, 0, 0, 2}, :tcp)
    RequestGuard.finish_request(:tcp)
  end

  defp clear_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end

  defp put_dns_config(overrides) do
    current = Application.get_env(:elektrine, :dns, [])
    Application.put_env(:elektrine, :dns, Keyword.merge(current, overrides))
  end
end
