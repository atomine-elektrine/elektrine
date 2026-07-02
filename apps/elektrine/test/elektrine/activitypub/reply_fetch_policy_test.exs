defmodule Elektrine.ActivityPub.ReplyFetchPolicyTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.ReplyFetchPolicy

  test "clamps preview fetch limits" do
    opts = ReplyFetchPolicy.clamp_fetch_opts(max_replies: 999_999, max_depth: 99, max_pages: 99)

    assert opts[:max_replies] == 5
    assert opts[:max_depth] == 3
    assert opts[:max_pages] == 10
  end

  test "clamps full thread fetch limits" do
    opts =
      ReplyFetchPolicy.clamp_fetch_opts(
        [max_replies: 999_999, max_depth: 99, max_pages: 999_999],
        :full_thread
      )

    assert opts[:max_replies] == 1_000
    assert opts[:max_depth] == 5
    assert opts[:max_pages] == 500
  end

  test "keeps same-host supplemental replies only" do
    replies = [
      %{"id" => "https://example.com/notes/1", "inReplyTo" => "https://example.com/notes/root"},
      %{
        "id" => "https://other.example/notes/2",
        "inReplyTo" => "https://other.example/notes/root"
      }
    ]

    assert [%{"id" => "https://example.com/notes/1"}] =
             ReplyFetchPolicy.filter_same_host_replies(replies, "https://example.com/notes/root")
  end
end
