defmodule Elektrine.ActivityPub.LemmyApiTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.LemmyApi

  describe "community_post_url?/1" do
    test "matches supported community post URL patterns" do
      assert LemmyApi.community_post_url?("https://lemmy.world/post/123")
      assert LemmyApi.community_post_url?("https://lemmy.world/post/123?sort=Top")
      assert LemmyApi.community_post_url?("https://piefed.social/c/tech/p/456")
      assert LemmyApi.community_post_url?("https://mbin.social/m/linux/t/789")
    end

    test "does not classify Bluesky post URLs as community posts" do
      refute LemmyApi.community_post_url?(
               "https://bsky.app/profile/alice.bsky.social/post/3l7nla7xq2s2d"
             )
    end
  end
end
