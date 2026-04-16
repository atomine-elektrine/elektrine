defmodule ElektrineWeb.Components.Social.TimelinePostTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview
  alias ElektrineSocialWeb.Components.Social.TimelinePost

  test "lemmy layout uses cached link preview image as thumbnail for link posts" do
    Repo.insert!(%LinkPreview{
      url: "https://example.com/story",
      status: "success",
      image_url: "https://example.com/story-preview.jpg"
    })

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: %{
          id: 123,
          activitypub_id: "https://remote.example/posts/123",
          activitypub_url: "https://example.com/story",
          post_type: "message",
          content: nil,
          inserted_at: ~N[2026-04-16 00:00:00],
          media_urls: [],
          like_count: 5,
          reply_count: 2,
          remote_actor: %Actor{
            username: "alice",
            domain: "lemmy.world"
          },
          link_preview: nil,
          media_metadata: %{}
        },
        layout: :lemmy,
        source: "remote_profile",
        current_user: nil,
        user_likes: %{},
        user_downvotes: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        lemmy_counts: %{},
        interaction_mode: :vote,
        clickable: true,
        on_image_click: nil,
        replies: []
      )

    assert html =~ ~s(src="https://example.com/story-preview.jpg")
    refute html =~ "hero-link w-8 h-8 text-primary"
  end
end
