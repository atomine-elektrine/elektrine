defmodule Elektrine.Social.FiltersTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social.FeedPolicy
  alias Elektrine.Social.Filters

  describe "boosted content filtering" do
    test "a boost of keyword-filtered content is hidden even when the wrapper is clean" do
      viewer = user_fixture()
      booster = user_fixture()
      author = user_fixture()

      # Viewer follows the booster (so the share is in home scope) but filters a
      # keyword that only appears in the *boosted* content, not the wrapper.
      {:ok, _} = Elektrine.Profiles.follow_user(viewer.id, booster.id)

      original = post_fixture(%{user: author, content: "megaspoiler ahead"})

      {:ok, _filter} =
        Filters.create_filter(viewer.id, %{
          kind: "keyword",
          value: "megaspoiler",
          contexts: ["home"]
        })

      {:ok, share} =
        Elektrine.Social.share_to_timeline(original.id, booster.id,
          visibility: "public",
          comment: ""
        )

      share =
        Elektrine.Repo.preload(share, shared_message: [:sender, :remote_actor])

      # The share wrapper itself carries no filtered keyword, but the boosted
      # content does — it must still be filtered out of the home feed.
      assert FeedPolicy.filter_home_posts(viewer.id, [share]) == []
    end

    test "a boost of muted local content is hidden even when the booster is followed" do
      viewer = user_fixture()
      booster = user_fixture()
      muted_author = user_fixture()

      {:ok, _} = Elektrine.Profiles.follow_user(viewer.id, booster.id)
      assert {:ok, _mute} = Elektrine.Accounts.mute_user(viewer.id, muted_author.id)

      original = post_fixture(%{user: muted_author, content: "quiet original"})

      {:ok, share} =
        Elektrine.Social.share_to_timeline(original.id, booster.id,
          visibility: "public",
          comment: ""
        )

      share =
        Elektrine.Repo.preload(share, shared_message: [:sender, :remote_actor])

      assert FeedPolicy.filter_home_posts(viewer.id, [share]) == []
    end
  end

  describe "social filters" do
    test "filters timeline posts by keyword and context" do
      viewer = user_fixture()
      author = user_fixture()
      post = post_fixture(%{user: author, content: "this contains spoilers"})

      assert {:ok, _filter} =
               Filters.create_filter(viewer.id, %{
                 kind: "keyword",
                 value: "spoilers",
                 contexts: ["home"]
               })

      assert Filters.filtered?(viewer.id, post, :home)
      refute Filters.filtered?(viewer.id, post, :notifications)
    end

    test "feed policy uses stored filters" do
      viewer = user_fixture()
      author = user_fixture()
      post = post_fixture(%{user: author, content: "launch leak"})

      assert {:ok, _filter} =
               Filters.create_filter(viewer.id, %{
                 kind: "keyword",
                 value: "leak",
                 contexts: ["notifications"]
               })

      refute FeedPolicy.visible_for_notification?(viewer.id, post)
    end

    test "expired filters are ignored" do
      viewer = user_fixture()
      author = user_fixture()
      post = post_fixture(%{user: author, content: "old mute"})

      assert {:ok, _filter} =
               Filters.create_filter(viewer.id, %{
                 kind: "keyword",
                 value: "old",
                 expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)
               })

      refute Filters.filtered?(viewer.id, post, :home)
    end

    test "media and sensitive filters do not require values" do
      viewer = user_fixture()
      author = user_fixture()

      media_post =
        media_post_fixture(%{
          user: author,
          content: "photo",
          media_urls: ["https://example.com/a.jpg"]
        })

      sensitive_post =
        post_fixture(%{
          user: author,
          content: "cw"
        })
        |> Map.put(:content_warning, "spoiler")

      assert {:ok, _media} = Filters.create_filter(viewer.id, %{kind: "media"})
      assert {:ok, _sensitive} = Filters.create_filter(viewer.id, %{kind: "sensitive"})

      assert Filters.filtered?(viewer.id, media_post, :home)
      assert Filters.filtered?(viewer.id, sensitive_post, :home)
    end
  end
end
