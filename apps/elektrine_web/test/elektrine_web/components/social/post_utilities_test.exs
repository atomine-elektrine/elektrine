defmodule ElektrineWeb.Components.Social.PostUtilitiesTest do
  use ExUnit.Case, async: true

  alias ElektrineWeb.Components.Social.PostUtilities

  test "local image post navigates to local timeline detail" do
    post = %{
      federated: false,
      activitypub_id: nil,
      post_type: "post",
      media_urls: ["timeline-attachments/photo.jpg"]
    }

    assert PostUtilities.get_post_click_event(post) == "navigate_to_post"
  end

  test "federated post with activitypub id navigates to remote detail" do
    post = %{
      federated: true,
      activitypub_id: "https://remote.example/users/alice/statuses/123",
      post_type: "post",
      media_urls: []
    }

    assert PostUtilities.get_post_click_event(post) == "navigate_to_remote_post"
  end

  test "has_community_uri?/1 ignores blank and public audience values" do
    blank_post = %{media_metadata: %{"community_actor_uri" => "   "}}

    public_post = %{
      media_metadata: %{"community_actor_uri" => "https://www.w3.org/ns/activitystreams#Public"}
    }

    refute PostUtilities.has_community_uri?(blank_post)
    refute PostUtilities.has_community_uri?(public_post)
  end

  test "has_community_uri?/1 ignores person actor URIs" do
    mastodon_style = %{
      media_metadata: %{"community_actor_uri" => "https://mastodon.social/@alice"}
    }

    user_path_style = %{
      media_metadata: %{"community_actor_uri" => "https://remote.example/users/alice"}
    }

    refute PostUtilities.has_community_uri?(mastodon_style)
    refute PostUtilities.has_community_uri?(user_path_style)
  end

  test "has_community_uri?/1 ignores Mastodon followers collections" do
    post = %{
      media_metadata: %{"community_actor_uri" => "https://mastodon.social/users/alice/followers"}
    }

    refute PostUtilities.has_community_uri?(post)
  end

  test "community_actor_uri/1 normalizes valid community values" do
    post = %{media_metadata: %{"community_actor_uri" => "  https://lemmy.world/c/elixir  "}}

    assert PostUtilities.community_actor_uri(post) == "https://lemmy.world/c/elixir"
    assert PostUtilities.has_community_uri?(post)
  end

  test "community_post?/1 falls back to URL pattern when metadata is absent" do
    post = %{activitypub_id: "https://lemmy.world/post/12345"}

    assert PostUtilities.community_post?(post)
  end

  test "community_post?/1 does not match non-numeric /post URLs" do
    post = %{activitypub_id: "https://bsky.app/profile/alice/post/3kfqj5"}

    refute PostUtilities.community_post?(post)
  end

  test "render_content_preview/2 strips html and decodes known emoji shortcodes" do
    content = "<p>Hello :smile: <strong>world</strong></p>"

    preview = PostUtilities.render_content_preview(content, "lemmy.world")

    assert preview == "Hello 😊 world"
  end

  test "render_content_preview/3 honors max length while preserving emoji decoding" do
    content = "<p>:smile: wave</p>"

    preview = PostUtilities.render_content_preview(content, "lemmy.world", 7)

    assert preview == "😊"
  end

  test "plain_text_content/1 strips malformed html fragments and decodes entities" do
    content =
      "<p>We&#39;re live now with No Agenda episode 1849 #@pocketnoagenda <a href=\"https://example.com/live\""

    assert PostUtilities.plain_text_content(content) ==
             "We're live now with No Agenda episode 1849 #@pocketnoagenda"
  end

  test "render_content_preview/2 does not leak escaped raw html from malformed content" do
    content =
      "<p>We&#39;re live now with No Agenda episode 1849 #@pocketnoagenda <a href=\"https://example.com/live\""

    preview = PostUtilities.render_content_preview(content, nil)

    assert preview =~ "We&#39;re live now with No Agenda episode 1849"
    refute preview =~ "&lt;p&gt;"
    refute preview =~ "href="
  end

  test "get_instance_domain/1 prefers remote actor domain" do
    post = %{remote_actor: %{domain: "lemmy.world"}}

    assert PostUtilities.get_instance_domain(post) == "lemmy.world"
  end

  test "get_instance_domain/1 falls back to activitypub host" do
    post = %{activitypub_id: "https://lemmy.world/post/123"}

    assert PostUtilities.get_instance_domain(post) == "lemmy.world"
  end

  test "get_reply_avatar_url/1 returns author_avatar for lemmy reply maps" do
    reply = %{
      author: "alice",
      author_domain: "lemmy.world",
      author_avatar: "https://lemmy.world/pictrs/image/alice.png"
    }

    assert PostUtilities.get_reply_avatar_url(reply) ==
             "https://lemmy.world/pictrs/image/alice.png"
  end

  test "get_reply_avatar_url/1 supports string-keyed lemmy metadata" do
    reply = %{
      "_lemmy" => %{
        "creator_name" => "bob",
        "creator_avatar" => "https://lemmy.world/pictrs/image/bob.png"
      }
    }

    assert PostUtilities.get_reply_avatar_url(reply) == "https://lemmy.world/pictrs/image/bob.png"
  end

  test "get_reply_author/1 supports string-keyed remote_actor maps" do
    reply = %{"remote_actor" => %{"username" => "carol", "domain" => "remote.example"}}

    assert PostUtilities.get_reply_author(reply) == "@carol@remote.example"
  end

  test "get_display_counts/3 prefers net votes for vote-style posts" do
    post = %{
      id: 123,
      activitypub_id: "https://remote.example/post/123",
      post_type: "discussion",
      upvotes: 5,
      downvotes: 2,
      like_count: 99,
      reply_count: 4
    }

    lemmy_counts = %{
      post.activitypub_id => %{upvotes: 8, downvotes: 3, score: 42, comments: 6}
    }

    assert PostUtilities.get_display_counts(post, lemmy_counts, %{}) == {5, 6}
  end

  test "get_display_counts/3 keeps like counts for non-vote posts" do
    post = %{
      id: 124,
      activitypub_id: "https://remote.example/status/123",
      post_type: "post",
      like_count: 7,
      reply_count: 2
    }

    lemmy_counts = %{
      post.activitypub_id => %{score: 11, comments: 4}
    }

    assert PostUtilities.get_display_counts(post, lemmy_counts, %{}) == {11, 4}
  end

  test "get_display_counts/3 falls back to cached federated reply metadata" do
    post = %{
      id: 125,
      activitypub_id: "https://remote.example/post/125",
      post_type: "discussion",
      reply_count: 0,
      media_metadata: %{
        "reply_count" => 9,
        "comments" => %{"totalItems" => 12},
        "remote_engagement" => %{"replies" => 7}
      }
    }

    assert PostUtilities.get_display_counts(post, %{}, %{}) == {0, 12}
  end
end
