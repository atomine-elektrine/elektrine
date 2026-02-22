defmodule ElektrineWeb.RemotePostLiveShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo
  alias ElektrineWeb.RemotePostLive.Show

  test "renders custom emoji in remote comment author display name" do
    actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/alice",
        username: "alice",
        domain: "remote.example",
        display_name: "Alice :blobcat:",
        inbox_url: "https://remote.example/inbox",
        public_key: "test-public-key"
      })
      |> Repo.insert!()

    %CustomEmoji{}
    |> CustomEmoji.changeset(%{
      shortcode: "blobcat",
      image_url: "https://remote.example/emoji/blobcat.png",
      instance_domain: actor.domain,
      visible_in_picker: false,
      disabled: false
    })
    |> Repo.insert!()

    comments = [
      %{
        reply: %{
          "id" => "https://remote.example/notes/1",
          "attributedTo" => actor.uri,
          "content" => "hello",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0}
        },
        depth: 0,
        children: []
      }
    ]

    assigns = %{
      __changed__: %{},
      community_actor: nil,
      remote_actor: %{domain: "remote.example"},
      post_interactions: %{},
      lemmy_comment_counts: %{},
      post: %{"id" => "https://remote.example/posts/1"},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.render_threaded_comments(comments)
      |> rendered_to_string()

    assert html =~ "Alice"
    assert html =~ "custom-emoji"
    assert html =~ "blobcat.png"
  end
end
