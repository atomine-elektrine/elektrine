defmodule Elektrine.ActivityPub.MentionsTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Mentions

  test "extract_local_mentions ignores non-federated domain handles" do
    mentions = Mentions.extract_local_mentions("hello @alice and @x.com and @bob@remote.example")

    assert Enum.map(mentions, & &1.username) == ["alice"]
  end

  test "extract_local_mentions includes full local-domain mentions" do
    mentions = Mentions.extract_local_mentions("hello @alice@#{ActivityPub.instance_domain()}")

    assert [%{username: "alice", handle: handle}] = mentions
    assert handle == "alice@#{ActivityPub.instance_domain()}"
  end

  test "extract_non_fediverse_mentions finds domain-style handles" do
    mentions =
      Mentions.extract_non_fediverse_mentions("hello @x.com and @news.example and alex@x.com")

    assert Enum.map(mentions, & &1.handle) == ["x.com", "news.example", "alex@x.com"]
  end

  test "count_mentions treats @x.com as one mention token" do
    assert Mentions.count_mentions("@alice @bob@remote.example @x.com alex@x.com") == 4
  end
end
