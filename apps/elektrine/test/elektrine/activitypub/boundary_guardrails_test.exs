defmodule Elektrine.ActivityPub.BoundaryGuardrailsTest do
  use ExUnit.Case, async: true

  @direct_fetch_pattern ~r/(?:Elektrine\.)?ActivityPub\.Fetcher\.(?:fetch_object|fetch_actor|webfinger_lookup)|(?<!Remote)Fetcher\.(?:fetch_object|fetch_actor|webfinger_lookup)/
  @ui_fetch_pattern ~r/(?:RemoteFetch|ActivityPub\.RemoteFetch|ActivityPub\.Fetcher|Fetcher)\.(?:fetch_object|fetch_actor|webfinger_lookup)/

  test "remote ActivityPub fetches go through the RemoteFetch boundary" do
    allowed = MapSet.new(["apps/elektrine/lib/elektrine/activitypub/remote_fetch.ex"])

    violations =
      "apps/**/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> files_matching(@direct_fetch_pattern)

    assert violations == []
  end

  test "LiveViews and components do not fetch remote ActivityPub resources directly" do
    violations =
      [
        "apps/**/lib/**/*_web/live/**/*.ex",
        "apps/**/lib/**/*_web/components/**/*.ex"
      ]
      |> Enum.flat_map(&Path.wildcard/1)
      |> files_matching(@ui_fetch_pattern)

    assert violations == []
  end

  defp files_matching(paths, pattern) do
    paths
    |> Enum.sort()
    |> Enum.filter(fn path ->
      path
      |> File.read!()
      |> Regex.match?(pattern)
    end)
  end
end
