defmodule Paige.ScraperThrottleTest do
  use ExUnit.Case, async: true

  alias Paige.ScraperThrottle

  test "spaces requests per source and opens a temporary block circuit" do
    source = {:test, System.unique_integer([:positive])}

    assert :ok = ScraperThrottle.acquire(source, 5_000)
    assert {:error, {:throttled, retry_ms}} = ScraperThrottle.acquire(source, 5_000)
    assert retry_ms > 0

    assert :ok = ScraperThrottle.block(source, 2)
    assert {:error, {:blocked, retry_seconds}} = ScraperThrottle.acquire(source, 0)
    assert retry_seconds in 1..2
  end
end
