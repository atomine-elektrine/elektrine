defmodule Elektrine.Messaging.FederationIngressRateLimiterTest do
  use ExUnit.Case, async: false

  alias Elektrine.Messaging.Federation.IngressRateLimiter

  @now 1_751_623_260

  setup do
    original_config = Application.get_env(:elektrine, :messaging_federation, [])

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, original_config)
    end)

    IngressRateLimiter.reset()
    {:ok, domain: "peer-#{System.unique_integer([:positive])}.test"}
  end

  defp put_limits(overrides) do
    config =
      Application.get_env(:elektrine, :messaging_federation, [])
      |> Keyword.merge(overrides)

    Application.put_env(:elektrine, :messaging_federation, config)
  end

  test "peer lane requests under the limit pass", %{domain: domain} do
    put_limits(ingress_peer_sync_requests_per_minute: 3)

    for _ <- 1..3 do
      assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)
    end
  end

  test "peer lane requests over the limit return rate_limited with retry-after", %{
    domain: domain
  } do
    put_limits(ingress_peer_sync_requests_per_minute: 2)

    assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)
    assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)

    assert {:error, :rate_limited, retry_after} =
             IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)

    assert retry_after == 60 - rem(@now, 60)
    assert retry_after in 1..60
  end

  test "peer lanes use independent buckets", %{domain: domain} do
    put_limits(
      ingress_peer_sync_requests_per_minute: 1,
      ingress_peer_replay_requests_per_minute: 1,
      ingress_peer_ephemeral_items_per_minute: 1
    )

    assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)
    assert {:error, :rate_limited, _} = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)

    assert :ok = IngressRateLimiter.check_peer(domain, :replay, 1, now: @now)
    assert :ok = IngressRateLimiter.check_peer(domain, :ephemeral, 1, now: @now)
  end

  test "per-room bucket limits durable events independently of the peer bucket", %{
    domain: domain
  } do
    put_limits(
      ingress_peer_durable_events_per_minute: 100,
      ingress_room_durable_events_per_minute: 2
    )

    assert :ok = IngressRateLimiter.check_durable(domain, ["stream:a"], now: @now)
    assert :ok = IngressRateLimiter.check_durable(domain, ["stream:a"], now: @now)

    assert {:error, :rate_limited, _} =
             IngressRateLimiter.check_durable(domain, ["stream:a"], now: @now)

    # A different room under the same peer still has capacity.
    assert :ok = IngressRateLimiter.check_durable(domain, ["stream:b"], now: @now)
  end

  test "peer durable bucket limits across rooms", %{domain: domain} do
    put_limits(
      ingress_peer_durable_events_per_minute: 2,
      ingress_room_durable_events_per_minute: 100
    )

    assert :ok = IngressRateLimiter.check_durable(domain, ["stream:a"], now: @now)
    assert :ok = IngressRateLimiter.check_durable(domain, ["stream:b"], now: @now)

    assert {:error, :rate_limited, _} =
             IngressRateLimiter.check_durable(domain, ["stream:c"], now: @now)
  end

  test "a batch exceeding remaining capacity is rejected up front without consuming budget", %{
    domain: domain
  } do
    put_limits(
      ingress_peer_durable_events_per_minute: 5,
      ingress_room_durable_events_per_minute: 100
    )

    oversized = Enum.map(1..6, fn index -> "stream:#{index}" end)

    assert {:error, :rate_limited, _} =
             IngressRateLimiter.check_durable(domain, oversized, now: @now)

    # The rejected batch left the buckets untouched, so a full-size batch fits.
    exact = Enum.map(1..5, fn index -> "stream:#{index}" end)
    assert :ok = IngressRateLimiter.check_durable(domain, exact, now: @now)
  end

  test "a batch rejected by a room bucket rolls back the peer reservation", %{domain: domain} do
    put_limits(
      ingress_peer_durable_events_per_minute: 4,
      ingress_room_durable_events_per_minute: 2
    )

    assert {:error, :rate_limited, _} =
             IngressRateLimiter.check_durable(
               domain,
               ["stream:a", "stream:a", "stream:a"],
               now: @now
             )

    assert :ok = IngressRateLimiter.check_durable(domain, ["stream:a", "stream:a"], now: @now)
  end

  test "events without a stream id count only against the peer bucket", %{domain: domain} do
    put_limits(
      ingress_peer_durable_events_per_minute: 2,
      ingress_room_durable_events_per_minute: 1
    )

    assert :ok = IngressRateLimiter.check_durable(domain, [nil, nil], now: @now)
    assert {:error, :rate_limited, _} = IngressRateLimiter.check_durable(domain, [nil], now: @now)
  end

  test "window reset restores capacity", %{domain: domain} do
    put_limits(ingress_peer_replay_requests_per_minute: 1)

    assert :ok = IngressRateLimiter.check_peer(domain, :replay, 1, now: @now)

    assert {:error, :rate_limited, _} =
             IngressRateLimiter.check_peer(domain, :replay, 1, now: @now)

    assert :ok = IngressRateLimiter.check_peer(domain, :replay, 1, now: @now + 60)
  end

  test "exempt domains bypass all buckets", %{domain: domain} do
    put_limits(
      ingress_peer_sync_requests_per_minute: 1,
      ingress_room_durable_events_per_minute: 1,
      ingress_rate_limit_exempt_domains: [String.upcase(domain)]
    )

    for _ <- 1..3 do
      assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)
      assert :ok = IngressRateLimiter.check_durable(domain, ["stream:a"], now: @now)
    end
  end

  test "official relay hosts are exempt", %{domain: domain} do
    put_limits(
      ingress_peer_sync_requests_per_minute: 1,
      official_relays: [%{"url" => "https://#{domain}"}]
    )

    for _ <- 1..3 do
      assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)
    end
  end

  test "disabled flag bypasses limiting", %{domain: domain} do
    put_limits(
      ingress_rate_limit_enabled: false,
      ingress_peer_sync_requests_per_minute: 1
    )

    for _ <- 1..3 do
      assert :ok = IngressRateLimiter.check_peer(domain, :sync, 1, now: @now)
    end
  end
end
