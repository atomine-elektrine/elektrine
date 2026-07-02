defmodule Elektrine.Social.FiltersTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social.FeedPolicy
  alias Elektrine.Social.Filters

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
