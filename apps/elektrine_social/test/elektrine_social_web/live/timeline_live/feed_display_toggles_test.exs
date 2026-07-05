defmodule ElektrineSocialWeb.TimelineLive.FeedDisplayTogglesTest do
  use ExUnit.Case, async: true

  alias ElektrineSocialWeb.TimelineLive.Operations.Helpers

  defp visible?(post, opts) do
    Helpers.post_matches_feed_display_toggles?(
      post,
      Keyword.get(opts, :hide_boosts, false),
      Keyword.get(opts, :hide_replies, false)
    )
  end

  describe "hide_boosts" do
    test "hides local boosts (share wrapper with no content)" do
      post = %{shared_message_id: 42, content: "", media_metadata: %{}}

      refute visible?(post, hide_boosts: true)
      assert visible?(post, hide_boosts: false)
    end

    test "keeps quote posts (share wrapper with commentary)" do
      post = %{shared_message_id: 42, content: "hot take", media_metadata: %{}}

      assert visible?(post, hide_boosts: true)
    end

    test "hides incoming federated boosts marked via boosted_by metadata" do
      post = %{
        shared_message_id: nil,
        content: "original remote post content",
        media_metadata: %{"boosted_by" => %{"username" => "someone", "domain" => "remote.tld"}}
      }

      refute visible?(post, hide_boosts: true)
      assert visible?(post, hide_boosts: false)
    end

    test "keeps ordinary posts" do
      post = %{shared_message_id: nil, content: "hello", media_metadata: %{}}

      assert visible?(post, hide_boosts: true)
    end
  end

  describe "hide_replies" do
    test "hides local replies" do
      post = %{reply_to_id: 7, media_metadata: %{}}

      refute visible?(post, hide_replies: true)
      assert visible?(post, hide_replies: false)
    end

    test "hides federated replies marked via inReplyTo metadata" do
      post = %{reply_to_id: nil, media_metadata: %{"inReplyTo" => "https://remote.tld/note/1"}}

      refute visible?(post, hide_replies: true)
    end

    test "keeps top-level posts" do
      post = %{reply_to_id: nil, media_metadata: %{}}

      assert visible?(post, hide_replies: true)
    end
  end
end
