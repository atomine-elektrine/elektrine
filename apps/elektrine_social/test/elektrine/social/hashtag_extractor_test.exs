defmodule Elektrine.Social.HashtagExtractorTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social.HashtagExtractor

  describe "get_posts_for_hashtag/2" do
    test "supports any, all, and none tag filters" do
      viewer = user_fixture()
      author = user_fixture()

      any_match = post_fixture(%{user: author, content: "any #kairo #phoenix"})
      HashtagExtractor.process_hashtags_for_message(any_match.id, ["kairo", "phoenix"])

      all_match = post_fixture(%{user: author, content: "all #kairo #elixir"})
      HashtagExtractor.process_hashtags_for_message(all_match.id, ["kairo", "elixir"])

      rejected = post_fixture(%{user: author, content: "reject #kairo #spam"})
      HashtagExtractor.process_hashtags_for_message(rejected.id, ["kairo", "spam"])

      post_ids =
        "kairo"
        |> HashtagExtractor.get_posts_for_hashtag(
          user_id: viewer.id,
          any_tags: ["phoenix"],
          all_tags: ["elixir"],
          none_tags: ["spam"],
          limit: 20
        )
        |> Enum.map(& &1.id)

      assert post_ids == [all_match.id]
      refute any_match.id in post_ids
      refute rejected.id in post_ids
    end
  end
end
