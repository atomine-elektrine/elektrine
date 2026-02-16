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

  test "community_actor_uri/1 normalizes valid community values" do
    post = %{media_metadata: %{"community_actor_uri" => "  https://lemmy.world/c/elixir  "}}

    assert PostUtilities.community_actor_uri(post) == "https://lemmy.world/c/elixir"
    assert PostUtilities.has_community_uri?(post)
  end

  test "render_content_preview/2 strips html and decodes known emoji shortcodes" do
    content = "<p>Hello :smile: <strong>world</strong></p>"

    preview = PostUtilities.render_content_preview(content, "lemmy.world")

    assert preview == "Hello 😊 world"
  end

  test "get_instance_domain/1 prefers remote actor domain" do
    post = %{remote_actor: %{domain: "lemmy.world"}}

    assert PostUtilities.get_instance_domain(post) == "lemmy.world"
  end

  test "get_instance_domain/1 falls back to activitypub host" do
    post = %{activitypub_id: "https://lemmy.world/post/123"}

    assert PostUtilities.get_instance_domain(post) == "lemmy.world"
  end
end
