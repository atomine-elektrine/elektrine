defmodule ElektrineWeb.Components.Social.TimelinePostTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview
  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineSocialWeb.Components.Social.TimelinePost

  test "lemmy layout uses cached link preview image as thumbnail for link posts" do
    Repo.insert!(%LinkPreview{
      url: "https://example.com/story",
      status: "success",
      image_url: "https://example.com/story-preview.jpg"
    })

    post =
      %{
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
      }
      |> then(&PostUtilities.attach_cached_link_previews([&1]))
      |> hd()

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
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

  test "lemmy layout shows 0 when vote score is unavailable" do
    html =
      render_component(&TimelinePost.timeline_post/1,
        post: %{
          id: 456,
          activitypub_id: "https://lemmy.world/post/456",
          activitypub_url: "https://lemmy.world/post/456",
          post_type: "message",
          content: nil,
          inserted_at: ~N[2026-04-16 00:00:00],
          media_urls: [],
          like_count: 0,
          dislike_count: 0,
          reply_count: 2,
          score: 0,
          upvotes: 0,
          downvotes: 0,
          remote_actor: %Actor{
            username: "alice",
            domain: "lemmy.world"
          },
          link_preview: nil,
          media_metadata: %{
            "community_actor_uri" => "https://lemmy.world/c/test",
            "type" => "Page"
          }
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

    assert html =~ ~s(aria-label="Score: 0")
    refute html =~ "Score unavailable"
    refute html =~ ">...<"
  end
end
