defmodule ElektrineWeb.RemotePostLiveShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Messaging.Message
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

  test "renders nested timeline replies directly without continuation link" do
    comments = [
      %{
        reply: %{
          "id" => "https://remote.example/notes/1",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "Parent",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0}
        },
        depth: 0,
        children: [
          %{
            reply: %{
              "id" => "https://remote.example/notes/2",
              "attributedTo" => "https://remote.example/users/bob",
              "content" => "Nested child",
              "published" => "2025-01-01T00:01:00Z",
              "likes" => %{"totalItems" => 0}
            },
            depth: 1,
            children: [
              %{
                reply: %{
                  "id" => "https://remote.example/notes/3",
                  "attributedTo" => "https://remote.example/users/carol",
                  "content" => "Deep child",
                  "published" => "2025-01-01T00:02:00Z",
                  "likes" => %{"totalItems" => 0}
                },
                depth: 2,
                children: []
              }
            ]
          }
        ]
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

    assert html =~ "Deep child"
    refute html =~ "Continue 1 nested reply on origin thread"
  end

  test "uses mastodon account fallback for avatar and profile link when actor cache misses" do
    comments = [
      %{
        reply: %{
          "id" => "https://remote.example/notes/1",
          "attributedTo" => "https://mastodon.social/users/bobby",
          "content" => "Fallback author data",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0},
          "_mastodon_account" => %{
            "username" => "bobby",
            "acct" => "bobby@mastodon.social",
            "display_name" => "Bobby",
            "avatar" => "https://mastodon.social/avatars/original/missing.png",
            "url" => "https://mastodon.social/@bobby"
          }
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

    assert html =~ "Bobby"
    assert html =~ "https://mastodon.social/avatars/original/missing.png"
    assert html =~ "/remote/bobby@mastodon.social"
  end

  test "renders local post when sender is missing" do
    quoted_message = %Message{
      id: 98_765,
      content: "Quoted local content",
      sender: nil,
      remote_actor: nil
    }

    local_message = %{
      id: 12_345,
      sender: nil,
      title: "Local title",
      content: "Local content",
      post_type: nil,
      poll: nil,
      quoted_message_id: quoted_message.id,
      quoted_message: quoted_message,
      media_urls: [],
      like_count: 0,
      reply_count: 0,
      share_count: 0,
      inserted_at: ~N[2026-02-25 03:31:05]
    }

    assigns = %{
      __changed__: %{},
      z: %{},
      loading: false,
      load_error: nil,
      is_local_post: true,
      local_message: local_message,
      post: nil,
      remote_actor: nil,
      community_actor: nil,
      community_stats: %{members: 0, posts: 0},
      is_community_post: false,
      is_following_community: false,
      is_pending_community: false,
      replies: [],
      threaded_replies: [],
      replies_loading: false,
      replies_loaded: true,
      comment_sort: "hot",
      post_interactions: %{},
      user_saves: %{},
      lemmy_counts: nil,
      mastodon_counts: nil,
      show_reply_form: false,
      reply_content: "",
      quick_reply_recent_replies: [],
      replying_to_comment_id: nil,
      comment_reply_content: "",
      show_image_modal: false,
      modal_image_url: nil,
      modal_images: [],
      modal_image_index: 0,
      modal_post: nil,
      post_reactions: %{},
      in_reply_to: nil,
      reply_parent: nil,
      reply_parent_actor: nil,
      reply_ancestors: [],
      current_user: nil
    }

    html =
      assigns
      |> Show.render()
      |> rendered_to_string()

    assert html =~ "Deleted user"
    assert html =~ "@deleted"
    assert html =~ "Local title"
    assert html =~ "/remote/post/98765"
  end
end
