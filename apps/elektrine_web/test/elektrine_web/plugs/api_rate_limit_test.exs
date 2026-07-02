defmodule ElektrineWeb.Plugs.APIRateLimitTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.API.{
    ImportRateLimiter,
    MediaRateLimiter,
    RateLimiter,
    SearchRateLimiter,
    TimelineRateLimiter,
    WriteRateLimiter
  }

  alias ElektrineWeb.Plugs.APIRateLimit

  setup do
    ensure_rate_limiter_started(RateLimiter, :api_rate_limiter)
    ensure_rate_limiter_started(ImportRateLimiter, :api_import_rate_limiter)
    ensure_rate_limiter_started(MediaRateLimiter, :api_media_rate_limiter)
    ensure_rate_limiter_started(SearchRateLimiter, :api_search_rate_limiter)
    ensure_rate_limiter_started(TimelineRateLimiter, :api_timeline_rate_limiter)
    ensure_rate_limiter_started(WriteRateLimiter, :api_write_rate_limiter)

    identifiers = [
      {:api_rate_limiter, RateLimiter, "activitypub:ip:198.51.100.10"},
      {:api_rate_limiter, RateLimiter, "ip:198.51.100.11"},
      {:api_import_rate_limiter, ImportRateLimiter, "ip:198.51.100.13"},
      {:api_media_rate_limiter, MediaRateLimiter, "ip:198.51.100.14"},
      {:api_search_rate_limiter, SearchRateLimiter, "ip:198.51.100.11"},
      {:api_timeline_rate_limiter, TimelineRateLimiter, "ip:198.51.100.12"},
      {:api_write_rate_limiter, WriteRateLimiter, "ip:198.51.100.15"}
    ]

    Enum.each(identifiers, fn {_table, limiter, identifier} ->
      limiter.clear_limits(identifier)
    end)

    on_exit(fn ->
      Enum.each(identifiers, fn {_table, limiter, identifier} ->
        limiter.clear_limits(identifier)
      end)
    end)

    {:ok, identifiers: identifiers}
  end

  test "rate limited responses do not require a negotiated Phoenix format", %{
    identifiers: identifiers
  } do
    {_table, _limiter, identifier} =
      Enum.find(identifiers, &match?({:api_rate_limiter, _, "activitypub:" <> _}, &1))

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

  test "search API paths use the search limiter bucket" do
    identifier = "ip:198.51.100.11"
    :ets.insert(:api_search_rate_limiter, {identifier, [], System.system_time(:second) + 60})

    conn =
      :get
      |> Plug.Test.conn("/api/v2/search?q=test")
      |> Map.put(:remote_ip, {198, 51, 100, 11})
      |> APIRateLimit.call(enabled_in_test: true)

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "x-ratelimit-limit") == ["20"]
  end

  test "timeline API paths use the timeline limiter bucket" do
    identifier = "ip:198.51.100.12"
    :ets.insert(:api_timeline_rate_limiter, {identifier, [], System.system_time(:second) + 60})

    conn =
      :get
      |> Plug.Test.conn("/api/v1/timelines/home")
      |> Map.put(:remote_ip, {198, 51, 100, 12})
      |> APIRateLimit.call(enabled_in_test: true)

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "x-ratelimit-limit") == ["40"]
  end

  test "media API paths use the media limiter bucket" do
    identifier = "ip:198.51.100.14"
    :ets.insert(:api_media_rate_limiter, {identifier, [], System.system_time(:second) + 60})

    conn =
      :post
      |> Plug.Test.conn("/api/v2/media")
      |> Map.put(:remote_ip, {198, 51, 100, 14})
      |> APIRateLimit.call(enabled_in_test: true)

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "x-ratelimit-limit") == ["10"]
  end

  test "bulk import API paths use the import limiter bucket" do
    identifier = "ip:198.51.100.13"
    :ets.insert(:api_import_rate_limiter, {identifier, [], System.system_time(:second) + 60})

    conn =
      :post
      |> Plug.Test.conn("/api/v1/pleroma/import")
      |> Map.put(:remote_ip, {198, 51, 100, 13})
      |> APIRateLimit.call(enabled_in_test: true)

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "x-ratelimit-limit") == ["3"]
  end

  test "compatible API write paths use the write limiter bucket" do
    identifier = "ip:198.51.100.15"
    :ets.insert(:api_write_rate_limiter, {identifier, [], System.system_time(:second) + 60})

    conn =
      :post
      |> Plug.Test.conn("/api/v1/statuses")
      |> Map.put(:remote_ip, {198, 51, 100, 15})
      |> APIRateLimit.call(enabled_in_test: true)

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "x-ratelimit-limit") == ["30"]
  end

  defp ensure_rate_limiter_started(module, table) do
    case :ets.whereis(table) do
      :undefined -> start_supervised!(module)
      _table -> :ok
    end
  end
end
