defmodule Elektrine.ActivityPub.FetchRemotePostRepliesTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub

  test "does not raise when collection fields are URL strings" do
    post_object = %{
      "id" => "https://example.com/posts/1",
      "url" => "https://example.com/posts/1",
      "type" => "Note",
      "replies" => "http://127.0.0.1:1/replies",
      "comments" => "http://127.0.0.1:1/comments",
      "repliesCount" => "0"
    }

    result = ActivityPub.fetch_remote_post_replies(post_object, limit: 1)

    assert is_tuple(result)
    assert tuple_size(result) == 2
    assert elem(result, 0) in [:ok, :error]
  end
end
