defmodule ElektrineSocialWeb.RemotePostLiveShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.AppCache
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.Votes
  alias ElektrineSocialWeb.RemotePostLive.Interactions
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

  test "standard timeline reply previews render with borders and post nav links" do
    assigns = %{
      __changed__: %{},
      show_reply_form: true,
      current_user: %{id: 1},
      quick_reply_recent_replies: [
        %{
          "id" => "https://remote.example/notes/preview-1",
          "attributedTo" => "https://remote.example/users/alice",
          "content" => "Preview reply",
          "published" => "2025-01-01T00:00:00Z"
        }
      ],
      reply_content: "",
      reply_content_domain: "remote.example",
      replying_to_comment_id: nil,
      show_recent_replies_preview: true
    }

    html =
      assigns
      |> Show.standard_timeline_detail_reply_box()
      |> rendered_to_string()

    assert html =~ "timeline-thread-preview-item relative"
    assert html =~ "border border-base-300"
    assert html =~ "data-post-nav-link"

    assert html =~
             "/remote/post/https%3A%2F%2Fremote.example%2Fnotes%2Fpreview-1"
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

  test "retries loading remote post community stats while cache is still empty" do
    actor_id = System.unique_integer([:positive])
    AppCache.put_remote_user_community_stats(actor_id, %{members: 0, posts: 0})

    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          community_actor: %{id: actor_id},
          community_stats: %{members: 0, posts: 0}
        }
      }

    assert {:noreply, ^socket} =
             Show.handle_info({:reload_remote_post_community_stats, actor_id, 1}, socket)

    assert_receive {:reload_remote_post_community_stats, ^actor_id, 2}, 1_700
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

  test "post_counts_updated clears optimistic vote delta for the main remote post" do
    local_message = %{
      id: 42,
      activitypub_id: "https://remote.example/posts/42",
      like_count: 10,
      share_count: 2,
      reply_count: 3
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: local_message,
        post: %{"id" => local_message.activitypub_id, "like_count" => 10},
        modal_post: nil,
        lemmy_counts: %{score: 10, comments: 3},
        mastodon_counts: %{},
        post_interactions: %{
          local_message.activitypub_id => %{
            liked: false,
            boosted: false,
            like_delta: 0,
            boost_delta: 0,
            vote: "up",
            vote_delta: 1
          }
        }
      }
    }

    assert {:noreply, updated_socket} =
             Show.handle_info(
               {:post_counts_updated,
                %{
                  message_id: local_message.id,
                  counts: %{like_count: 11, share_count: 2, reply_count: 3}
                }},
               socket
             )

    assert updated_socket.assigns.local_message.like_count == 11
    assert updated_socket.assigns.lemmy_counts.score == 11
    assert updated_socket.assigns.post_interactions[local_message.activitypub_id].vote == "up"
    assert updated_socket.assigns.post_interactions[local_message.activitypub_id].vote_delta == 0
  end

  test "vote_remote_target toggles an existing remote vote off in storage" do
    user = AccountsFixtures.user_fixture()

    actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/voter",
        username: "voter",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/voter/inbox",
        public_key: "test-public-key-voter"
      })
      |> Repo.insert!()

    activitypub_id = "https://remote.example/posts/toggle-vote"

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "toggle vote",
        title: "Toggle vote",
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: actor.id
      })

    assert {:ok, _vote} = Votes.vote_on_message(user.id, message.id, "up")
    assert Votes.get_user_vote(user.id, message.id) == "up"

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: user,
        post_interactions: %{
          activitypub_id => %{
            liked: false,
            boosted: false,
            like_delta: 0,
            boost_delta: 0,
            vote: "up",
            vote_delta: 0
          }
        }
      }
    }

    assert {:noreply, updated_socket} =
             Interactions.vote_remote_target(socket, activitypub_id, "up")

    assert Votes.get_user_vote(user.id, message.id) == nil
    assert updated_socket.assigns.post_interactions[activitypub_id].vote == nil
    assert updated_socket.assigns.post_interactions[activitypub_id].vote_delta == -1
  end

  test "cached community posts keep community audience when loading replies" do
    msg = %{
      activitypub_id: "https://slrpnk.net/post/36219249",
      activitypub_url: "https://slrpnk.net/post/36219249",
      reply_count: 2,
      media_metadata: %{"community_actor_uri" => "https://lemmy.ml/c/asklemmy"},
      media_urls: [],
      remote_actor: nil,
      title: "Ask Lemmy",
      content: "",
      inserted_at: ~N[2026-04-06 09:48:25],
      primary_url: nil,
      link_preview: nil,
      reply_to_id: nil,
      conversation: nil,
      post_type: nil
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comment_sort: "hot",
        current_user: nil,
        post_interactions: %{},
        post_reactions: %{},
        is_community_post: false
      }
    }

    assert {:noreply, _updated_socket} = Show.handle_info({:load_replies_for_cached, msg}, socket)

    assert_received {:load_replies, post_object}
    assert post_object["id"] == "https://slrpnk.net/post/36219249"
    assert post_object["type"] == "Page"
    assert post_object["audience"] == "https://lemmy.ml/c/asklemmy"

    assert post_object["to"] == [
             "https://lemmy.ml/c/asklemmy",
             "https://www.w3.org/ns/activitystreams#Public"
           ]
  end

  test "cached federated posts loaded by local id use cached remote replies flow" do
    unique = System.unique_integer([:positive])
    activitypub_id = "https://lemmy.world/post/#{unique}"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://lemmy.world/u/test#{unique}",
        username: "test#{unique}",
        domain: "lemmy.world",
        inbox_url: "https://lemmy.world/u/test#{unique}/inbox",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "cached federated post",
        title: "Remote Lemmy post",
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 11,
        media_metadata: %{"community_actor_uri" => "https://lemmy.ml/c/linux"}
      })

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        comment_sort: "hot",
        current_user: nil,
        is_community_post: false,
        post_interactions: %{},
        post_reactions: %{},
        trust_topic_tracked: false
      }
    }

    message_id = message.id

    assert {:noreply, updated_socket} = Show.handle_info({:load_local_post, message_id}, socket)

    assert updated_socket.assigns.post["id"] == activitypub_id
    assert updated_socket.assigns.remote_actor.id == remote_actor.id
    assert updated_socket.assigns.replies_loading

    assert_received {:load_replies_for_cached, %{id: ^message_id}}
    assert_received {:load_platform_counts, ^activitypub_id}
  end

  test "remote_post_loaded denies cached non-public federated posts to unauthorized viewers" do
    unique = System.unique_integer([:positive])
    activitypub_id = "https://remote.example/posts/private-#{unique}"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/private#{unique}",
        username: "private#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/private#{unique}/inbox",
        public_key: "test-public-key-private-#{unique}"
      })
      |> Repo.insert!()

    {:ok, _message} =
      Messaging.create_federated_message(%{
        content: "followers-only federated post",
        title: "Private remote post",
        visibility: "followers",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id
      })

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: nil, remote_post_load_ref: 7}
    }

    post_object = %{
      "id" => activitypub_id,
      "url" => activitypub_id,
      "to" => ["https://remote.example/users/private#{unique}/followers"],
      "cc" => []
    }

    assert {:noreply, updated_socket} =
             Show.handle_info(
               {:remote_post_loaded, 7,
                {:ok, %{post: post_object, actor: remote_actor, community: nil}}},
               socket
             )

    assert updated_socket.assigns.load_error == "Post not found"
    assert inspect(updated_socket.redirected) =~ "/"
  end

  test "remote_post_loaded renders before remote cache hydration finishes" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/fast#{unique}",
        username: "fast#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/fast#{unique}/inbox",
        public_key: "test-public-key-fast-#{unique}"
      })
      |> Repo.insert!()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_user: nil,
        remote_post_load_ref: 9,
        loading: true,
        replies_loading: false,
        post_interactions: %{},
        is_community_post: false,
        community_actor: nil,
        community_stats: %{members: 0, posts: 0},
        community_lookup_complete: false,
        is_following_community: false,
        is_pending_community: false,
        current_url: "https://elektrine.test/remote/post/test",
        post_reactions: %{},
        user_saves: %{}
      }
    }

    post_object = %{
      "id" => "https://remote.example/posts/#{unique}",
      "url" => "https://remote.example/posts/#{unique}",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "name" => "Fast render post",
      "content" => "Shows before hydration"
    }

    assert {:noreply, updated_socket} =
             Show.handle_info(
               {:remote_post_loaded, 9,
                {:ok, %{post: post_object, actor: remote_actor, community: nil}}},
               socket
             )

    refute updated_socket.assigns.loading
    assert updated_socket.assigns.post == post_object
    assert updated_socket.assigns.remote_actor.id == remote_actor.id
    assert is_nil(updated_socket.assigns.local_message)

    post_id = post_object["id"]

    assert_received {:hydrate_loaded_remote_post, ^post_object, ^remote_actor}
    assert_received {:load_platform_counts, ^post_id}
    refute_received {:load_replies, ^post_object}
  end

  test "load_replies waits for hydration when no cached local message exists" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: nil,
        replies_loading: false,
        replies_loaded: false
      }
    }

    post_object = %{"id" => "https://remote.example/posts/no-cache"}

    assert {:noreply, updated_socket} = Show.handle_info({:load_replies, post_object, []}, socket)

    assert updated_socket.assigns.replies_loading
    refute updated_socket.assigns.replies_loaded
  end

  test "cached Mastodon posts do not get inferred as community posts from followers collections" do
    post_object = %{
      "id" => "https://mastodon.social/users/alice/statuses/123",
      "url" => "https://mastodon.social/@alice/123",
      "cc" => ["https://mastodon.social/users/alice/followers"]
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        is_community_post: false,
        local_message: nil,
        page_title: "Post by @alice@mastodon.social",
        remote_actor: nil
      }
    }

    assert {:noreply, updated_socket} =
             Show.handle_info({:cached_post_object_loaded, post_object}, socket)

    refute updated_socket.assigns.is_community_post
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
