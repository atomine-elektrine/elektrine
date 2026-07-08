defmodule Elektrine.PathsTest do
  use ExUnit.Case, async: true

  describe "post_path/1" do
    test "routes local community posts with ActivityPub ids to their community path" do
      post = %{
        id: 494,
        title: "Local Post",
        activitypub_id: "http://localhost:4000/c/maxfield/posts/494",
        federated: false,
        conversation: %{type: "community", name: "maxfield"}
      }

      assert Elektrine.Paths.post_path(post) == "/discussions/maxfield/p/494-local-post"
    end

    test "routes federated posts to the local remote-post view" do
      post = %{
        id: 494,
        activitypub_id: "https://example.social/posts/494",
        federated: true,
        conversation: %{type: "community", name: "maxfield"}
      }

      assert Elektrine.Paths.post_path(post) == "/remote/post/494"
    end
  end
end
