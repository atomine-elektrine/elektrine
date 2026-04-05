defmodule ElektrineSocialWeb.RemotePostLiveShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview
  alias ElektrineSocialWeb.RemotePostLive.Show

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

  test "renders markdown embeds inside remote comment content" do
    comments = [
      %{
        reply: %{
          "id" => "https://lemmy.world/comment/markdown-1",
          "attributedTo" => "https://lemmy.world/u/lemmy_bob",
          "content" =>
            "![](https://lemmy.world/pictrs/image/example.png)\n\n> quoted text\n\n[TEE](https://en.wikipedia.org/wiki/Trusted_execution_environment)",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0},
          "_lemmy" => %{"creator_name" => "Lemmy Bob"}
        },
        depth: 0,
        children: []
      }
    ]

    assigns = %{
      __changed__: %{},
      community_actor: %{domain: "lemmy.world"},
      remote_actor: %{domain: "lemmy.world"},
      post_interactions: %{},
      lemmy_comment_counts: %{},
      post: %{"id" => "https://lemmy.world/post/1"},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.render_threaded_comments(comments)
      |> rendered_to_string()

    assert html =~ ~s(src="https://lemmy.world/pictrs/image/example.png")
    assert html =~ "<blockquote>"
    assert html =~ ~s(href="https://en.wikipedia.org/wiki/Trusted_execution_environment")
    assert html =~ ">TEE<"
  end

  test "navigates embedded local post URLs" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}

    assert {:noreply, updated_socket} =
             Show.handle_event(
               "navigate_to_embedded_post",
               %{"url" => "/timeline/post/42"},
               socket
             )

    assert inspect(updated_socket.redirected) =~ "/timeline/post/42"
  end

  test "routes embedded remote post URLs through remote post detail" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}

    assert {:noreply, updated_socket} =
             Show.handle_event(
               "navigate_to_embedded_post",
               %{"url" => "https://example.com/posts/1"},
               socket
             )

    assert inspect(updated_socket.redirected) =~
             "/remote/post/https%3A%2F%2Fexample.com%2Fposts%2F1"
  end

  test "ignores placeholder embedded post URLs" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}

    assert {:noreply, ^socket} =
             Show.handle_event(
               "navigate_to_embedded_post",
               %{"url" => "#"},
               socket
             )
  end

  test "toggle_reply_form clears active comment reply state" do
    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          show_reply_form: false,
          replying_to_comment_id: "https://remote.example/comments/1",
          comment_reply_content: "draft"
        }
      }

    assert {:noreply, updated_socket} = Show.handle_event("toggle_reply_form", %{}, socket)

    assert updated_socket.assigns.show_reply_form
    assert is_nil(updated_socket.assigns.replying_to_comment_id)
    assert updated_socket.assigns.comment_reply_content == ""
  end

  test "toggle_comment_reply closes the top-level quick reply form" do
    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          show_reply_form: true,
          replying_to_comment_id: nil,
          comment_reply_content: "stale"
        }
      }

    assert {:noreply, updated_socket} =
             Show.handle_event(
               "toggle_comment_reply",
               %{"comment_id" => "https://remote.example/comments/1"},
               socket
             )

    refute updated_socket.assigns.show_reply_form
    assert updated_socket.assigns.replying_to_comment_id == "https://remote.example/comments/1"
    assert updated_socket.assigns.comment_reply_content == ""
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
    assert html =~ ~s(aria-label="Open Bobby profile")
    refute html =~ ~s(alt="Bobby")
  end

  test "uses lemmy fallback avatar in remote community comment threads when actor cache misses" do
    comments = [
      %{
        reply: %{
          "id" => "https://lemmy.world/comment/1",
          "attributedTo" => "https://lemmy.world/u/lemmy_bob",
          "content" => "Lemmy fallback avatar data",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0},
          "_lemmy" => %{
            "creator_name" => "Lemmy Bob",
            "creator_avatar" => "https://lemmy.world/pictrs/image/avatar_bob.png"
          }
        },
        depth: 0,
        children: []
      }
    ]

    assigns = %{
      __changed__: %{},
      community_actor: %{domain: "lemmy.world"},
      remote_actor: %{domain: "lemmy.world"},
      post_interactions: %{},
      lemmy_comment_counts: %{},
      post: %{"id" => "https://lemmy.world/post/1"},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.render_threaded_comments(comments)
      |> rendered_to_string()

    assert html =~ "Lemmy Bob"
    assert html =~ "https://lemmy.world/pictrs/image/avatar_bob.png"
    assert html =~ "/remote/lemmy_bob@lemmy.world"
    assert html =~ ~s(aria-label="Open Lemmy Bob profile")
    refute html =~ ~s(alt="Lemmy Bob")
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

  test "renders YouTube embed for local link previews on remote post page" do
    link_preview = %LinkPreview{
      status: "success",
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      title: "Video title",
      description: "Video description"
    }

    local_message = %{
      id: 54_321,
      sender: nil,
      title: "Link post",
      content: "",
      post_type: nil,
      poll: nil,
      quoted_message_id: nil,
      quoted_message: nil,
      media_urls: [],
      link_preview: link_preview,
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

    assert html =~ "https://www.youtube.com/embed/dQw4w9WgXcQ"
    assert html =~ "Video title"
  end

  test "renders a stable loading placeholder while comments are loading" do
    local_message = %{
      id: 54_322,
      sender: nil,
      title: "Loading comments",
      content: "Post body",
      post_type: nil,
      poll: nil,
      quoted_message_id: nil,
      quoted_message: nil,
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
      replies_loading: true,
      replies_loaded: false,
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

    assert html =~ "data-comments-loading-placeholder"
    refute html =~ ">Load Comments<"
  end

  test "ancestor context links prefer post reference over actor profile url" do
    parent_post = %{
      "id" => "https://lemmy.sdf.org/comment/12345",
      "url" => "https://lemmy.sdf.org/u/deleted",
      "content" => "Parent content"
    }

    assigns = %{
      __changed__: %{},
      in_reply_to: "https://lemmy.sdf.org/comment/12345",
      reply_parent: nil,
      reply_parent_actor: nil,
      reply_ancestors: [
        %{
          post: parent_post,
          actor: nil,
          in_reply_to: "https://lemmy.sdf.org/comment/12345"
        }
      ],
      post_interactions: %{},
      user_saves: %{},
      post_reactions: %{},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.ancestor_context_stack()
      |> rendered_to_string()

    encoded_parent = URI.encode_www_form("https://lemmy.sdf.org/comment/12345")
    encoded_actor = URI.encode_www_form("https://lemmy.sdf.org/u/deleted")

    assert html =~ "/remote/post/#{encoded_parent}"
    refute html =~ "/remote/post/#{encoded_actor}"
  end
end
