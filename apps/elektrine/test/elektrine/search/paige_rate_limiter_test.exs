defmodule Elektrine.Search.PaigeRateLimiterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Elektrine.Search.PaigeRateLimiter

  test "atomically bounds concurrent external searches" do
    identifier = "paige-test:#{System.unique_integer([:positive])}"
    on_exit(fn -> PaigeRateLimiter.clear_limits(identifier) end)

    parent = self()

    capture_log(fn ->
      results =
        1..40
        |> Task.async_stream(
          fn _index -> PaigeRateLimiter.allow_query(identifier) end,
          max_concurrency: 40,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      send(parent, {:rate_limit_results, results})
    end)

    assert_receive {:rate_limit_results, results}
    assert Enum.count(results, &(&1 == :ok)) == 30
    assert Enum.count(results, &match?({:error, retry_after} when retry_after > 0, &1)) == 10
  end
end
