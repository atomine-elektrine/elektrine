defmodule ElektrineWeb.Plugs.APIRateLimitTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.API.RateLimiter
  alias ElektrineWeb.Plugs.APIRateLimit

  setup do
    ensure_rate_limiter_started()
    identifier = "activitypub:ip:198.51.100.10"
    RateLimiter.clear_limits(identifier)

    on_exit(fn -> RateLimiter.clear_limits(identifier) end)

    {:ok, identifier: identifier}
  end

  test "rate limited responses do not require a negotiated Phoenix format", %{
    identifier: identifier
  } do
    :ets.insert(:api_rate_limiter, {identifier, [], System.system_time(:second) + 60})

    conn =
      :post
      |> Plug.Test.conn("/inbox", "{}")
      |> Map.put(:remote_ip, {198, 51, 100, 10})
      |> APIRateLimit.call(key_prefix: "activitypub", ip_only: true, enabled_in_test: true)

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert Jason.decode!(conn.resp_body) == %{"errors" => %{"detail" => "Too Many Requests"}}
  end

  defp ensure_rate_limiter_started do
    case :ets.whereis(:api_rate_limiter) do
      :undefined -> start_supervised!(RateLimiter)
      _table -> :ok
    end
  end
end
