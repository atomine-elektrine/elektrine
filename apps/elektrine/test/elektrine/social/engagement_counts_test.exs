defmodule Elektrine.Social.EngagementCountsTest do
  use ExUnit.Case, async: true

  alias Elektrine.Social.EngagementCounts

  test "clamps remote counters to a non-negative trusted range" do
    assert EngagementCounts.remote_count(-10) == 0
    assert EngagementCounts.remote_count("42") == 42
    assert EngagementCounts.remote_count("bad") == 0
    assert EngagementCounts.remote_count(200_000_000) == EngagementCounts.max_remote_count()
  end

  test "stores zero remote counters as nil" do
    assert EngagementCounts.nullable_remote_count(0) == nil
    assert EngagementCounts.nullable_remote_count("0") == nil
    assert EngagementCounts.nullable_remote_count(5) == 5
  end
end
