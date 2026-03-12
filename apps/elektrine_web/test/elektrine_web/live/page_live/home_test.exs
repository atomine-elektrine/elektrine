defmodule ElektrineWeb.PageLive.HomeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ElektrineWeb.PageLive.Home

  test "load_platform_stats falls back to defaults when cache fetch fails" do
    reason = %RuntimeError{message: "query canceled"}

    log =
      capture_log(fn ->
        assert Home.load_platform_stats(fn _fetch_fn -> {:error, reason} end) == %{
                 stats: %{
                   users: 0,
                   emails: 0,
                   posts: 0
                 },
                 federation: %{
                   remote_actors: 0,
                   instances: 0
                 }
               }
      end)

    assert log =~ "Home platform stats cache fetch failed"
    assert log =~ "query canceled"
  end
end
