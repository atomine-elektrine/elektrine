defmodule ElektrineWeb.Components.Social.TimelinePostTest do
  use Elektrine.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo
  alias Elektrine.Social.Conversation
  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.Message
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

  test "timeline layout suppresses unsafe legacy remote URLs" do
    post =
      remote_post(%{
        activitypub_url: "javascript:alert(1)",
        remote_actor: %Actor{
          username: "alice",
          domain: "remote.example",
          avatar_url: "data:image/svg+xml,<svg/onload=alert(1)>"
        },
        link_preview: %LinkPreview{
          url: "javascript:alert(2)",
          status: "success",
          image_url: "http://127.0.0.1/private.png",
          favicon_url: "data:image/png;base64,AAAA",
          title: "Unsafe preview"
        }
      })

    html = render_timeline_post(post, "unsafe-remote")

    refute html =~ "javascript:alert"
    refute html =~ "data:image"
    refute html =~ "127.0.0.1"
    refute html =~ "Unsafe preview"
  end

  test "timeline layout suppresses self-referential remote post link previews" do
    post =
      remote_post(%{
        activitypub_id: "https://federate.social/users/mattblaze/statuses/116825697706046218",
        activitypub_url: "https://federate.social/@mattblaze/116825697706046218",
        primary_url: "https://federate.social/@mattblaze/116825697706046218",
        content: "Remote post content without a submitted link",
        remote_actor: %Actor{
          username: "mattblaze",
          domain: "federate.social"
        },
        link_preview: %LinkPreview{
          url: "https://federate.social/@mattblaze/116825697706046218",
          status: "success",
          title: "Matt Blaze remote status preview",
          site_name: "federate.social"
        }
      })

    html = render_timeline_post(post, "self-link-remote")

    refute html =~ "Matt Blaze remote status preview"
    refute html =~ ~s(class="mt-3 border border-base-300 rounded-lg overflow-hidden)
  end

  test "timeline actions prefer cached federated likes over stale local likes" do
    post = %Message{
      id: 789,
      activitypub_id: "https://remote.example/users/alice/statuses/789",
      activitypub_url: "https://remote.example/@alice/789",
      post_type: "post",
      content: "Remote post with cached engagement",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [],
      media_metadata: %{"original_like_count" => 14},
      like_count: 1,
      reply_count: 0,
      share_count: 0,
      score: 0,
      federated: true,
      remote_actor: %Actor{id: 789, username: "alice", domain: "remote.example"}
    }

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        layout: :timeline,
        source: "timeline",
        current_user: %{id: 1},
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: false,
        on_image_click: nil
      )

    like_button_text =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("#post-actions-789-like")
      |> Floki.text()

    assert String.trim(like_button_text) == "14"
  end

  test "timeline actions prefer cached federated shares over stale local shares" do
    post = %Message{
      id: 790,
      activitypub_id: "https://remote.example/users/alice/statuses/790",
      activitypub_url: "https://remote.example/@alice/790",
      post_type: "post",
      content: "Remote post with cached boosts",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [],
      media_metadata: %{"original_share_count" => 27},
      like_count: 0,
      reply_count: 0,
      share_count: 2,
      score: 0,
      federated: true,
      remote_actor: %Actor{id: 790, username: "alice", domain: "remote.example"}
    }

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        layout: :timeline,
        source: "timeline",
        current_user: %{id: 1},
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: false,
        on_image_click: nil
      )

    boost_button_text =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("#post-actions-790-boost")
      |> Floki.text()

    assert String.trim(boost_button_text) == "27"
  end

  test "timeline reply card click opens the reply detail instead of the parent thread" do
    post = %Message{
      id: 456,
      reply_to_id: 123,
      conversation: %Conversation{type: "timeline"},
      sender: nil,
      remote_actor: nil,
      post_type: "post",
      content: "Reply body",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [],
      media_metadata: %{},
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      score: 0
    }

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        layout: :timeline,
        source: "timeline",
        current_user: nil,
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: true,
        on_image_click: nil
      )

    assert html =~ "data-post-nav-link"
    assert html =~ ~s(href="/remote/post/456")
    refute html =~ ~s(href="/post/123#message-456")
  end

  test "federated timeline posts render remote media urls directly" do
    media_url = "https://remote.example/media/photo.jpg"

    post = %Message{
      id: 987,
      federated: true,
      activitypub_id: "https://remote.example/notes/987",
      activitypub_url: "https://remote.example/notes/987",
      post_type: "message",
      content: "Remote photo",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [media_url],
      media_metadata: %{},
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      quote_count: 0,
      dislike_count: 0,
      score: 0,
      remote_actor: %Actor{id: 987, username: "alice", domain: "remote.example"}
    }

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        layout: :timeline,
        source: "timeline",
        current_user: nil,
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: false,
        on_image_click: nil
      )

    assert html =~ ~s(src="#{media_url}")
  end

  test "federated timeline posts render video from media attachment metadata" do
    media_url = "https://remote.example/download/stream"

    post = %Message{
      id: 988,
      federated: true,
      activitypub_id: "https://remote.example/videos/watch/988",
      activitypub_url: "https://remote.example/videos/watch/988",
      post_type: "message",
      content: "Remote video",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [media_url],
      media_metadata: %{
        "media_attachments" => [
          %{
            "type" => "video",
            "mediaType" => "video/mp4",
            "url" => media_url,
            "width" => 1280,
            "height" => 720
          }
        ]
      },
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      quote_count: 0,
      dislike_count: 0,
      score: 0,
      remote_actor: %Actor{id: 988, username: "alice", domain: "remote.example"}
    }

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        layout: :timeline,
        source: "timeline",
        current_user: nil,
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: false,
        on_image_click: nil
      )

    assert html =~ "<video"
    assert html =~ ~s(src="#{media_url}")
    refute html =~ "media-image-988"
  end

  test "timeline child ids are scoped by id prefix" do
    quoted = %Message{
      id: 3319,
      post_type: "post",
      content: "Quoted body",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [],
      media_metadata: %{},
      sender: nil,
      remote_actor: %Actor{id: 668, username: "bob", domain: "remote.example"}
    }

    post = %Message{
      id: 3343,
      federated: true,
      activitypub_id: "https://remote.example/notes/3343",
      activitypub_url: "https://remote.example/notes/3343",
      post_type: "message",
      content: "Remote photo https://remote.example/content-photo.jpg",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: ["https://remote.example/media/photo.jpg"],
      media_metadata: %{},
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      score: 0,
      remote_actor: %Actor{id: 667, username: "alice", domain: "remote.example"},
      quoted_message_id: quoted.id,
      quoted_message: quoted,
      link_preview: %LinkPreview{
        url: "https://remote.example/story",
        status: "success",
        title: "Remote story",
        image_url: "https://remote.example/story.jpg",
        favicon_url: "https://remote.example/favicon.ico"
      }
    }

    first = render_timeline_post(post, "first")
    second = render_timeline_post(post, "second")

    assert duplicate_ids(first <> second) == []
  end

  test "timeline reactions escape raw HTML before emoji rendering" do
    post = %Message{
      id: 3401,
      federated: true,
      activitypub_id: "https://remote.example/notes/3401",
      activitypub_url: "https://remote.example/notes/3401",
      post_type: "message",
      content: "Reaction target",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [],
      media_metadata: %{},
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      score: 0,
      remote_actor: %Actor{id: 701, username: "alice", domain: "remote.example"}
    }

    raw_img = ~S|<img src=x onerror=alert(1)>|

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        id_prefix: "reaction-escape",
        layout: :timeline,
        source: "timeline",
        current_user: %{id: 1, is_admin: false},
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [
          %{
            emoji: raw_img,
            user: %{id: 2, username: "bob", handle: nil},
            user_id: 2,
            remote_actor: nil
          }
        ],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: false,
        on_image_click: nil
      )

    refute html =~ ~s(<img src=x)
    assert html =~ "&lt;img"
  end

  test "unresolved remote timeline cards link to the original external URL" do
    remote_url = "https://mastodon.social/users/camwilson/statuses/116678821688658069"

    html =
      render_compact_timeline_post(
        remote_post(%{id: nil, activitypub_id: remote_url, activitypub_url: remote_url})
      )

    assert html =~ ~s(href="#{remote_url}")
    refute html =~ "/remote/post/https%3A%2F%2Fmastodon.social"
  end

  test "cached remote timeline cards keep using local remote detail" do
    remote_url = "https://mastodon.social/users/camwilson/statuses/116678821688658069"

    html =
      render_compact_timeline_post(
        remote_post(%{id: 12_345, activitypub_id: remote_url, activitypub_url: remote_url})
      )

    assert html =~ ~s(href="/remote/post/12345")
    refute html =~ ~s(href="#{remote_url}")
  end

  test "profile timeline cards use remote detail instead of discussion route" do
    post = %Message{
      id: 3_031_092,
      reply_to_id: nil,
      conversation: %Conversation{type: "community", name: "heyitsluna"},
      sender: nil,
      remote_actor: nil,
      post_type: "post",
      title: "New community for my fans",
      content: "New community for my fans",
      inserted_at: ~N[2026-04-16 00:00:00],
      media_urls: [],
      media_metadata: %{},
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      score: 0,
      auto_title: false
    }

    html =
      render_component(&TimelinePost.timeline_post/1,
        post: post,
        layout: :timeline,
        source: "remote_profile",
        current_user: nil,
        user_likes: %{},
        user_boosts: %{},
        user_saves: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        user_statuses: %{},
        lemmy_counts: %{},
        post_replies: %{},
        post_interactions: %{},
        post_reactions_map: %{},
        reactions: [],
        show_follow_button: false,
        show_post_dropdown: false,
        clickable: true,
        on_image_click: nil
      )

    assert html =~ ~s(href="/remote/post/3031092")
    refute html =~ "/discussions/heyitsluna/p/3031092"
  end

  defp render_timeline_post(post, id_prefix) do
    render_component(&TimelinePost.timeline_post/1,
      post: post,
      id_prefix: id_prefix,
      layout: :timeline,
      source: "timeline",
      current_user: %{id: 1, is_admin: false},
      user_likes: %{},
      user_boosts: %{},
      user_saves: %{},
      user_follows: %{},
      pending_follows: %{},
      remote_follow_overrides: %{},
      user_statuses: %{},
      lemmy_counts: %{},
      post_replies: %{},
      post_interactions: %{},
      post_reactions_map: %{},
      reactions: [],
      show_follow_button: true,
      show_post_dropdown: true,
      clickable: false,
      on_image_click: nil
    )
  end

  defp render_compact_timeline_post(post) do
    render_component(&TimelinePost.timeline_post/1,
      post: post,
      layout: :compact,
      source: "timeline",
      current_user: nil,
      user_likes: %{},
      user_boosts: %{},
      user_saves: %{},
      user_follows: %{},
      pending_follows: %{},
      remote_follow_overrides: %{},
      user_statuses: %{},
      lemmy_counts: %{},
      post_replies: %{},
      post_interactions: %{},
      post_reactions_map: %{},
      reactions: [],
      clickable: true,
      on_image_click: nil
    )
  end

  defp remote_post(attrs) do
    defaults = %{
      id: 1,
      activitypub_id: "https://remote.example/posts/1",
      activitypub_url: "https://remote.example/posts/1",
      post_type: "post",
      content: "Remote post content",
      inserted_at: ~N[2026-04-16 00:00:00],
      edited_at: nil,
      media_urls: [],
      media_metadata: %{},
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      quote_count: 0,
      dislike_count: 0,
      score: 0,
      upvotes: 0,
      downvotes: 0,
      federated: true,
      remote_actor: %Actor{username: "camwilson", domain: "mastodon.social"},
      sender: nil,
      conversation: nil,
      link_preview: nil,
      poll: nil,
      title: nil,
      auto_title: nil,
      content_warning: nil,
      shared_message_id: nil,
      quoted_message_id: nil,
      quoted_message: nil,
      reply_to_id: nil
    }

    Map.merge(defaults, attrs)
  end

  defp duplicate_ids(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("[id]")
    |> Enum.flat_map(&Floki.attribute(&1, "id"))
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
    |> Enum.sort()
  end
end
