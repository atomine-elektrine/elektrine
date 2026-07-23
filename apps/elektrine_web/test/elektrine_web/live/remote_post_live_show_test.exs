defmodule ElektrineSocialWeb.RemotePostLiveShowTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Elektrine.SocialFixtures, only: [post_fixture: 1]

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.AppCache
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.Message
  alias Elektrine.Social.Votes
  alias ElektrineSocialWeb.RemotePostLive.Interactions
  alias ElektrineSocialWeb.RemotePostLive.Show
  alias ElektrineSocialWeb.RemotePostLive.SurfaceHelpers

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "reply author fallback rejects unsafe remote avatar URLs" do
    fallback =
      SurfaceHelpers.build_reply_author_fallback(
        %{
          "id" => "https://remote.example/notes/1",
          "author_avatar" => "https://user:pass@example.com/avatar.png",
          "attributedTo" => %{
            "id" => "https://remote.example/users/alice",
            "preferredUsername" => "alice",
            "icon" => %{"url" => "http://127.0.0.1/internal.png"}
          }
        },
        "https://remote.example/users/alice"
      )

    assert fallback.acct_label == "@alice@remote.example"
    assert fallback.profile_path == "/remote/alice@remote.example"
    refute fallback.avatar_url
  end

  test "remote detail helper prefers cached remote likes over stale local likes" do
    message = %Message{
      like_count: 1,
      upvotes: 0,
      score: 0,
      media_metadata: %{"original_like_count" => 20}
    }

    assert SurfaceHelpers.local_vote_display_count(message) == 20
  end

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
    assert html =~ "timeline-thread-comment-card"
    assert html =~ ~s(data-track-dwell="false")
  end

  test "renders short mentions in remote comments using in-reply-to author domain" do
    comments = [
      %{
        reply: %{
          "id" => "https://mas.to/users/helenclayton/statuses/1",
          "attributedTo" => "https://mas.to/users/helenclayton",
          "content" => "@louisa_ I started doing this",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0},
          "inReplyToAuthor" => "@louisa_@mastodon.social"
        },
        depth: 0,
        children: []
      }
    ]

    assigns = %{
      __changed__: %{},
      community_actor: nil,
      remote_actor: %{domain: "mastodon.social"},
      post_interactions: %{},
      lemmy_comment_counts: %{},
      post: %{"id" => "https://mastodon.social/posts/1"},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.render_threaded_comments(comments)
      |> rendered_to_string()

    assert html =~ ~s(href="/remote/louisa_@mastodon.social")
    refute html =~ ~s(/remote/louisa_@mas.to)
  end

  test "renders malformed remote comment content without crashing sanitizer" do
    comments = [
      %{
        reply: %{
          "id" => "https://mastodon.social/users/evawolfangel/statuses/1",
          "attributedTo" => "https://mastodon.social/users/evawolfangel",
          "content" =>
            "<html_sanitize_ex>@evawolfangel \n\nHaha, darauf habe ich gewartet, da der Link ja (wieder) fehlte. 🤔 ... Sicher bewusst, um Leute wie mich zu triggern. 😉\n\nKurze Frage: Wofür steht >> Drüko <<?</html_sanitize_ex>",
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
      remote_actor: %{domain: "mastodon.social"},
      post_interactions: %{},
      lemmy_comment_counts: %{},
      post: %{"id" => "https://mastodon.social/posts/1"},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.render_threaded_comments(comments)
      |> rendered_to_string()

    assert html =~ "@evawolfangel"
    assert html =~ "Wofür steht &gt;&gt; Drüko &lt;&lt;?"
    refute html =~ "html_sanitize_ex"
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

  test "renders Lemmy comment vote column from upvotes instead of net score" do
    comments = [
      %{
        reply: %{
          "id" => "https://lemmy.world/comment/123",
          "attributedTo" => "https://lemmy.world/u/lemmy_bob",
          "content" => "Vote count should use upvotes",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0},
          "_lemmy" => %{
            "creator_name" => "Lemmy Bob",
            "score" => 0,
            "upvotes" => 12
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

    assert html =~ "12"

    refute html =~
             ~s(<span class="text-xs font-medium text-base-content/60">\n            0\n          </span>)
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

  test "opens unresolved embedded remote post URLs externally" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}

    assert {:noreply, updated_socket} =
             Show.handle_event(
               "navigate_to_embedded_post",
               %{"url" => "https://example.com/posts/1"},
               socket
             )

    assert inspect(updated_socket.redirected) =~ ~s(external: "https://example.com/posts/1")
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

  test "cached federated media-only local posts render during initial load" do
    unique = System.unique_integer([:positive])
    activitypub_id = "https://remote.example/posts/media-only-#{unique}"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/media#{unique}",
        username: "media#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/media#{unique}/inbox",
        public_key: "test-public-key-media-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: nil,
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id,
        media_urls: ["https://remote.example/media/image.webp"]
      })

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, current_user: nil}
    }

    assert {:ok, updated_socket} =
             Show.mount(%{"post_id" => Integer.to_string(message.id)}, %{}, socket)

    refute updated_socket.assigns.loading
    assert updated_socket.assigns.post["id"] == activitypub_id
    assert updated_socket.assigns.remote_actor.id == remote_actor.id

    assert [%{"url" => "https://remote.example/media/image.webp"}] =
             updated_socket.assigns.post["attachment"]
  end

  test "cached federated PeerTube videos render a player on remote detail", %{conn: conn} do
    unique = System.unique_integer([:positive])
    activitypub_id = "https://peertube.example/videos/watch/#{unique}"
    video_url = "https://peertube.example/download/stream/#{unique}"
    preview_url = "https://peertube.example/lazy-static/previews/#{unique}.jpg"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://peertube.example/accounts/video#{unique}",
        username: "video#{unique}",
        domain: "peertube.example",
        inbox_url: "https://peertube.example/accounts/video#{unique}/inbox",
        public_key: "test-public-key-video-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "PeerTube video caption",
        title: "PeerTube video detail",
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id,
        media_urls: [video_url],
        media_metadata: %{
          "type" => "Video",
          "media_attachments" => [
            %{
              "type" => "video",
              "mediaType" => "video/mp4",
              "url" => video_url,
              "preview_url" => preview_url,
              "width" => 1280,
              "height" => 720
            }
          ]
        }
      })

    {:ok, _view, html} = live(conn, ~p"/remote/post/#{message.id}")

    assert html =~ "PeerTube video detail"
    assert html =~ "<video"
    assert html =~ ~s(src="#{video_url}")
    assert html =~ ~s(poster="#{preview_url}")
    refute html =~ ~s(<img src="#{video_url}")
  end

  test "platform count refresh does not lower an already displayed reply count" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/count#{unique}",
        username: "count#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/count#{unique}/inbox",
        public_key: "test-public-key-count-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "counted post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/#{unique}",
        activitypub_url: "https://remote.example/posts/#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 1
      })

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: message,
        post: %{
          "id" => message.activitypub_id,
          "reply_count" => 5,
          "repliesCount" => 5,
          "replies" => %{"totalItems" => 5},
          "comments" => %{"totalItems" => 5}
        },
        modal_post: nil,
        post_interactions: %{},
        lemmy_counts: nil,
        mastodon_counts: nil,
        platform_counts_load_ref: 42,
        platform_counts_refresh_ref: nil,
        is_community_post: false,
        community_actor: nil,
        community_stats: nil,
        current_user: nil,
        page_title: nil
      }
    }

    result = %{
      mastodon_counts: nil,
      lemmy_counts: nil,
      lemmy_comment_counts: nil,
      fresh_post: nil
    }

    assert {:noreply, updated_socket} =
             Show.handle_info(
               {:platform_counts_loaded, 42, message.activitypub_id, result},
               socket
             )

    assert updated_socket.assigns.post["reply_count"] == 5
    assert updated_socket.assigns.post["repliesCount"] == 5
    assert get_in(updated_socket.assigns.post, ["replies", "totalItems"]) == 5
  end

  test "cached reply loading uses database descendants when preloaded replies are stale" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/stale#{unique}",
        username: "stale#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/stale#{unique}/inbox",
        public_key: "test-public-key-stale-#{unique}"
      })
      |> Repo.insert!()

    {:ok, root_message} =
      Messaging.create_federated_message(%{
        content: "root",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/#{unique}",
        activitypub_url: "https://remote.example/posts/#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 2
      })

    {:ok, first_reply} =
      Messaging.create_federated_message(%{
        content: "first reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/#{unique}-1",
        activitypub_url: "https://remote.example/comments/#{unique}-1",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    {:ok, _second_reply} =
      Messaging.create_federated_message(%{
        content: "second reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/#{unique}-2",
        activitypub_url: "https://remote.example/comments/#{unique}-2",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    stale_message = %{root_message | replies: [first_reply]}

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

    assert {:noreply, updated_socket} =
             Show.handle_info({:load_replies_for_cached, stale_message}, socket)

    assert length(updated_socket.assigns.replies) == 2
    refute updated_socket.assigns.replies_loading
    assert updated_socket.assigns.replies_loaded
  end

  test "local-style remote thread replies link short mentions to parent actor domain" do
    unique = System.unique_integer([:positive])

    comments = [
      %{
        reply: %{
          "id" => "https://mas.to/users/helen#{unique}/statuses/#{unique}",
          "_local_message_id" => 99_000 + unique,
          "attributedTo" => "https://mas.to/users/helen#{unique}",
          "content" => "@louisa_#{unique} hello there",
          "published" => "2025-01-01T00:00:00Z",
          "likes" => %{"totalItems" => 0},
          "inReplyToAuthor" => "@louisa_#{unique}@mastodon.social"
        },
        depth: 0,
        children: []
      }
    ]

    assigns = %{
      __changed__: %{},
      community_actor: nil,
      remote_actor: %{domain: "mastodon.social"},
      post_interactions: %{},
      lemmy_comment_counts: %{},
      post: %{"id" => "https://mastodon.social/posts/#{unique}"},
      current_user: nil,
      replying_to_comment_id: nil,
      comment_reply_content: ""
    }

    html =
      assigns
      |> Show.render_threaded_comments(comments)
      |> rendered_to_string()

    assert html =~ ~s(href="/remote/louisa_#{unique}@mastodon.social")
    refute html =~ ~s(/remote/louisa_#{unique}@mas.to)
  end

  test "new_public_post refreshes displayed replies for ingested thread replies" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/thread#{unique}",
        username: "thread#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/thread#{unique}/inbox",
        public_key: "test-public-key-thread-#{unique}"
      })
      |> Repo.insert!()

    {:ok, root_message} =
      Messaging.create_federated_message(%{
        content: "root",
        title: "Root post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/#{unique}",
        activitypub_url: "https://remote.example/posts/#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id
      })

    {:ok, existing_reply} =
      Messaging.create_federated_message(%{
        content: "existing reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/#{unique}-1",
        activitypub_url: "https://remote.example/comments/#{unique}-1",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    {:ok, ingested_reply} =
      Messaging.create_federated_message(%{
        content: "ingested reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/#{unique}-2",
        activitypub_url: "https://remote.example/comments/#{unique}-2",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: existing_reply.id
      })

    root_message = Repo.preload(root_message, remote_actor: [])

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: root_message,
        post: %{"id" => root_message.activitypub_id},
        replies: [],
        comment_sort: "hot",
        current_user: nil,
        post_interactions: %{},
        post_reactions: %{}
      }
    }

    post_id = root_message.activitypub_id

    assert {:noreply, same_socket} = Show.handle_info({:new_public_post, ingested_reply}, socket)
    assert same_socket.assigns.replies == []
    assert_received {:replies_loaded, [], ^post_id}

    assert {:noreply, updated_socket} =
             Show.handle_info({:replies_loaded, [], post_id}, socket)

    reply_ids = Enum.map(updated_socket.assigns.replies, &(&1["id"] || &1[:id]))

    assert existing_reply.activitypub_id in reply_ids
    assert ingested_reply.activitypub_id in reply_ids
  end

  test "cached reply polling finishes without rebuilding unchanged comments" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/quiet#{unique}",
        username: "quiet#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/quiet#{unique}/inbox",
        public_key: "test-public-key-quiet-#{unique}"
      })
      |> Repo.insert!()

    {:ok, root_message} =
      Messaging.create_federated_message(%{
        content: "quiet root",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/quiet-#{unique}",
        activitypub_url: "https://remote.example/posts/quiet-#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 3
      })

    root_message = Repo.preload(root_message, remote_actor: [])
    root_message_id = root_message.id
    post_id = root_message.activitypub_id

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: root_message,
        post: %{"id" => post_id, "reply_count" => 3},
        replies: [],
        threaded_replies: [],
        thread_reply_actors: %{},
        comment_sort: "hot",
        current_user: nil,
        post_interactions: %{keep: true},
        post_reactions: %{},
        replies_loading: true,
        replies_loaded: false,
        pending_initial_comment_reveal: true,
        awaiting_initial_comment_counts: true,
        reply_sync_checked: false
      }
    }

    assert {:noreply, same_socket} =
             Show.handle_info({:refresh_cached_replies, root_message_id, post_id, 8}, socket)

    assert same_socket.assigns.replies == []
    assert same_socket.assigns.post_interactions == %{keep: true}
    assert_received {:cached_reply_sync_finished, ^root_message_id, ^post_id}
    refute_received {:replies_loaded, [], ^post_id}

    assert {:noreply, updated_socket} =
             Show.handle_info(
               {:cached_reply_sync_finished, root_message_id, post_id},
               same_socket
             )

    refute updated_socket.assigns.replies_loading
    refute updated_socket.assigns.replies_loaded
    refute updated_socket.assigns.pending_initial_comment_reveal
    refute updated_socket.assigns.awaiting_initial_comment_counts
    assert updated_socket.assigns.reply_sync_checked
    assert updated_socket.assigns.replies == []
    assert updated_socket.assigns.post_interactions == %{keep: true}
  end

  test "replies_loaded persists the discovered root reply count" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/persist#{unique}",
        username: "persist#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/persist#{unique}/inbox",
        public_key: "test-public-key-persist-#{unique}"
      })
      |> Repo.insert!()

    {:ok, root_message} =
      Messaging.create_federated_message(%{
        content: "root",
        title: "Root post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/persist-#{unique}",
        activitypub_url: "https://remote.example/posts/persist-#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 0
      })

    {:ok, first_reply} =
      Messaging.create_federated_message(%{
        content: "first reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/persist-#{unique}-1",
        activitypub_url: "https://remote.example/comments/persist-#{unique}-1",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    {:ok, _second_reply} =
      Messaging.create_federated_message(%{
        content: "second reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/persist-#{unique}-2",
        activitypub_url: "https://remote.example/comments/persist-#{unique}-2",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: first_reply.id
      })

    root_message = Repo.preload(root_message, remote_actor: [])

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: root_message,
        post: %{"id" => root_message.activitypub_id, "reply_count" => 0},
        replies: [],
        comment_sort: "hot",
        current_user: nil,
        post_interactions: %{},
        post_reactions: %{}
      }
    }

    assert {:noreply, updated_socket} =
             Show.handle_info({:replies_loaded, [], root_message.activitypub_id}, socket)

    assert updated_socket.assigns.local_message.reply_count == 2
    assert updated_socket.assigns.post["reply_count"] == 2
    assert Repo.get!(Message, root_message.id).reply_count == 2
  end

  test "cached threaded replies render persisted boost counts after reload" do
    unique = System.unique_integer([:positive])
    current_user = AccountsFixtures.user_fixture(%{username: "replyboost#{unique}"})

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/replyboost#{unique}",
        username: "replyboost#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/replyboost#{unique}/inbox",
        public_key: "test-public-key-replyboost-#{unique}"
      })
      |> Repo.insert!()

    {:ok, root_message} =
      Messaging.create_federated_message(%{
        content: "root",
        title: "Root post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/replyboost-#{unique}",
        activitypub_url: "https://remote.example/posts/replyboost-#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id
      })

    {:ok, reply} =
      Messaging.create_federated_message(%{
        content: "boosted reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/replyboost-#{unique}-1",
        activitypub_url: "https://remote.example/comments/replyboost-#{unique}-1",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    reply
    |> Ecto.Changeset.change(share_count: 1)
    |> Repo.update!()

    %Elektrine.Social.PostBoost{}
    |> Elektrine.Social.PostBoost.changeset(%{
      user_id: current_user.id,
      message_id: reply.id
    })
    |> Repo.insert!()

    root_message = Repo.preload(root_message, remote_actor: [])

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: root_message,
        post: %{"id" => root_message.activitypub_id},
        replies: [],
        comment_sort: "hot",
        current_user: current_user,
        post_interactions: %{},
        post_reactions: %{},
        user_follows: %{},
        pending_follows: %{},
        remote_follow_overrides: %{},
        lemmy_comment_counts: %{},
        community_actor: nil,
        is_community_post: false
      }
    }

    assert {:noreply, updated_socket} =
             Show.handle_info({:load_replies_for_cached, root_message}, socket)

    html =
      updated_socket.assigns
      |> Show.render_threaded_comments(updated_socket.assigns.threaded_replies)
      |> rendered_to_string()

    assert html =~ ~s(id="reply-card-#{reply.id}-boost-count")
    assert html =~ ~s(data-count="1")
    assert html =~ ~s(phx-click="unboost_post")

    refreshed_socket =
      Phoenix.Component.assign(updated_socket, :reply_counts_load_ref, 123)

    assert {:noreply, refreshed_socket} =
             Show.handle_info(
               {:reply_counts_loaded, 123,
                %{
                  reply.activitypub_id => %{
                    favourites_count: 4,
                    reblogs_count: 2,
                    replies_count: 3
                  }
                }},
               refreshed_socket
             )

    refreshed_html =
      refreshed_socket.assigns
      |> Show.render_threaded_comments(refreshed_socket.assigns.threaded_replies)
      |> rendered_to_string()

    assert refreshed_html =~ ~s(id="reply-card-#{reply.id}-like-count")
    assert refreshed_html =~ ~s(id="reply-card-#{reply.id}-boost-count")
    assert refreshed_html =~ ~s(id="reply-card-#{reply.id}-comment-count")
    assert refreshed_html =~ ~s(data-count="4")
    assert refreshed_html =~ ~s(data-count="2")
    assert refreshed_html =~ ~s(data-count="3")
  end

  test "replies_loaded re-resolves stale local message before persisting reply count" do
    unique = System.unique_integer([:positive])

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/reresolve#{unique}",
        username: "reresolve#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/reresolve#{unique}/inbox",
        public_key: "test-public-key-reresolve-#{unique}"
      })
      |> Repo.insert!()

    {:ok, stale_message} =
      Messaging.create_federated_message(%{
        content: "stale socket post",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/stale-#{unique}",
        activitypub_url: "https://remote.example/posts/stale-#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 0
      })

    {:ok, root_message} =
      Messaging.create_federated_message(%{
        content: "resolved root",
        visibility: "public",
        activitypub_id: "https://remote.example/posts/resolved-#{unique}",
        activitypub_url: "https://remote.example/posts/resolved-#{unique}",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_count: 0
      })

    {:ok, _first_reply} =
      Messaging.create_federated_message(%{
        content: "first reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/resolved-#{unique}-1",
        activitypub_url: "https://remote.example/comments/resolved-#{unique}-1",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    {:ok, _second_reply} =
      Messaging.create_federated_message(%{
        content: "second reply",
        visibility: "public",
        activitypub_id: "https://remote.example/comments/resolved-#{unique}-2",
        activitypub_url: "https://remote.example/comments/resolved-#{unique}-2",
        federated: true,
        remote_actor_id: remote_actor.id,
        reply_to_id: root_message.id
      })

    post_ref = root_message.activitypub_id <> "?ctx=reply#context"

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        local_message: stale_message,
        post: %{"id" => post_ref, "reply_count" => 0},
        replies: [],
        comment_sort: "hot",
        current_user: nil,
        post_interactions: %{},
        post_reactions: %{}
      }
    }

    assert {:noreply, updated_socket} =
             Show.handle_info({:replies_loaded, [], post_ref}, socket)

    assert updated_socket.assigns.local_message.id == root_message.id
    assert updated_socket.assigns.local_message.reply_count == 2
    assert Repo.get!(Message, root_message.id).reply_count == 2
    assert Repo.get!(Message, stale_message.id).reply_count == 0
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

  test "remote_post_loaded denies deleted federated posts even when the fetched object is public" do
    unique = System.unique_integer([:positive])
    activitypub_id = "https://remote.example/posts/deleted-#{unique}"

    remote_actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://remote.example/users/deleted#{unique}",
        username: "deleted#{unique}",
        domain: "remote.example",
        inbox_url: "https://remote.example/users/deleted#{unique}/inbox",
        public_key: "test-public-key-deleted-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        content: "deleted federated post",
        title: "Deleted remote post",
        visibility: "public",
        activitypub_id: activitypub_id,
        activitypub_url: activitypub_id,
        federated: true,
        remote_actor_id: remote_actor.id
      })

    {:ok, message} =
      message
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()

    assert message.deleted_at

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: nil, remote_post_load_ref: 11}
    }

    post_object = %{
      "id" => activitypub_id,
      "url" => activitypub_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "name" => "Deleted remote post",
      "content" => "This should not be shown"
    }

    assert {:noreply, updated_socket} =
             Show.handle_info(
               {:remote_post_loaded, 11,
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
      e_nav_badge_counts: nil,
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
      e_nav_badge_counts: nil,
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

  test "renders cached community score before fresh lemmy counts load" do
    activitypub_id = "https://lemmy.world/post/137"

    local_message = %{
      id: 54_322,
      federated: true,
      activitypub_id: activitypub_id,
      activitypub_url: activitypub_id,
      sender: nil,
      remote_actor: %{
        username: "alice",
        domain: "lemmy.world",
        display_name: "Alice",
        avatar_url: nil,
        avatar: nil,
        uri: "https://lemmy.world/u/alice"
      },
      title: "Cached Lemmy score",
      content: "Post body",
      post_type: nil,
      poll: nil,
      quoted_message_id: nil,
      quoted_message: nil,
      media_urls: [],
      media_metadata: %{},
      primary_url: nil,
      link_preview: nil,
      like_count: 0,
      reply_count: 5,
      share_count: 0,
      upvotes: 0,
      downvotes: 0,
      score: 4321,
      inserted_at: ~N[2026-02-25 03:31:05]
    }

    assigns = %{
      __changed__: %{},
      e_nav_badge_counts: nil,
      z: %{},
      loading: false,
      load_error: nil,
      is_local_post: true,
      local_message: local_message,
      post: %{
        "id" => activitypub_id,
        "url" => activitypub_id,
        "type" => "Page",
        "name" => "Cached Lemmy score",
        "content" => "Post body",
        "published" => "2026-02-25T03:31:05Z",
        "likes" => %{"totalItems" => 0},
        "shares" => %{"totalItems" => 0},
        "replies" => %{"totalItems" => 5},
        "repliesCount" => 5,
        "reply_count" => 5,
        "score" => 4321,
        "attributedTo" => "https://lemmy.world/u/alice"
      },
      remote_actor: %{
        username: "alice",
        domain: "lemmy.world",
        display_name: "Alice",
        avatar_url: nil,
        avatar: nil,
        uri: "https://lemmy.world/u/alice"
      },
      community_actor: %{
        username: "tech",
        domain: "lemmy.world",
        display_name: "Tech",
        avatar_url: nil,
        avatar: nil,
        uri: "https://lemmy.world/c/tech",
        summary: nil,
        published_at: nil
      },
      community_stats: %{members: 0, posts: 0},
      is_community_post: true,
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
      lemmy_comment_counts: %{},
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

    assert html =~ ~r/>\s*4321\s*</
    assert html =~ "hero-arrow-up"
    assert html =~ "hero-arrow-down"
    refute html =~ "hero-heart"
  end

  test "remote detail prefers updated local interaction state for display counts" do
    user = AccountsFixtures.user_fixture()
    activitypub_id = "https://remote.example/posts/local-state"

    local_message = %{
      id: 54_323,
      federated: true,
      activitypub_id: activitypub_id,
      activitypub_url: activitypub_id,
      sender: nil,
      remote_actor: %{
        id: 54_323,
        username: "alice",
        domain: "remote.example",
        display_name: "Alice",
        avatar_url: nil,
        avatar: nil,
        uri: "https://remote.example/users/alice"
      },
      title: nil,
      content: "Post body",
      post_type: nil,
      poll: nil,
      quoted_message_id: nil,
      quoted_message: nil,
      media_urls: [],
      media_metadata: %{},
      primary_url: nil,
      link_preview: nil,
      like_count: 10,
      reply_count: 0,
      share_count: 0,
      upvotes: 0,
      downvotes: 0,
      score: 10,
      inserted_at: ~N[2026-02-25 03:31:05]
    }

    assigns = %{
      __changed__: %{},
      e_nav_badge_counts: nil,
      z: %{},
      loading: false,
      load_error: nil,
      is_local_post: true,
      local_message: local_message,
      post: %{
        "id" => activitypub_id,
        "url" => activitypub_id,
        "type" => "Note",
        "content" => "Post body",
        "published" => "2026-02-25T03:31:05Z",
        "likes" => %{"totalItems" => 10},
        "shares" => %{"totalItems" => 0},
        "replies" => %{"totalItems" => 0},
        "attributedTo" => "https://remote.example/users/alice"
      },
      remote_actor: local_message.remote_actor,
      community_actor: nil,
      community_stats: %{members: 0, posts: 0},
      is_community_post: false,
      is_following_community: false,
      is_pending_community: false,
      is_following_author: false,
      is_pending_author: false,
      user_follows: %{},
      pending_follows: %{},
      remote_follow_overrides: %{},
      replies: [],
      threaded_replies: [],
      replies_loading: false,
      replies_loaded: true,
      comment_sort: "hot",
      post_interactions: %{
        activitypub_id => %{liked: false, boosted: false, like_delta: 0, boost_delta: 0},
        Integer.to_string(local_message.id) => %{
          liked: true,
          boosted: false,
          like_delta: 1,
          boost_delta: 0
        }
      },
      user_saves: %{},
      lemmy_counts: nil,
      lemmy_comment_counts: %{},
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
      pending_remote_poll_vote: nil,
      in_reply_to: nil,
      reply_parent: nil,
      reply_parent_actor: nil,
      reply_ancestors: [],
      current_user: user,
      platform_counts_load_ref: nil
    }

    html =
      assigns
      |> Show.render()
      |> rendered_to_string()

    assert html =~ ~s(data-count="11")
    assert html =~ "hero-heart-solid"
  end

  test "local post detail opened from portal activity increments like and boost counts", %{
    conn: conn
  } do
    author = AccountsFixtures.user_fixture()
    viewer = AccountsFixtures.user_fixture()
    post = post_fixture(%{user: author, content: "Queue opened post"})

    {:ok, view, _html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/post/#{post.id}")

    html = render_hook(view, "like_post", %{"message_id" => Integer.to_string(post.id)})

    assert Repo.get(Message, post.id).like_count == 1
    assert html =~ ~s(phx-click="unlike_post")
    assert html =~ ~s(data-count="1")

    html = render_hook(view, "boost_post", %{"message_id" => Integer.to_string(post.id)})

    assert Repo.get(Message, post.id).share_count == 1
    assert html =~ ~s(phx-click="unboost_post")
    assert html =~ ~s(data-count="1")
  end

  test "boost wrapper detail targets original post for likes, boosts, and reactions", %{
    conn: conn
  } do
    author = AccountsFixtures.user_fixture()
    booster = AccountsFixtures.user_fixture()
    viewer = AccountsFixtures.user_fixture()
    original = post_fixture(%{user: author, content: "Original boosted post"})

    assert {:ok, _boost} = Elektrine.Social.boost_post(booster.id, original.id)

    wrapper =
      Repo.get_by!(Message, sender_id: booster.id, shared_message_id: original.id)
      |> Repo.preload([:sender, shared_message: [:sender]])

    {:ok, view, html} =
      conn
      |> log_in_user(viewer)
      |> live("/remote/post/#{wrapper.id}")

    document = Floki.parse_document!(html)

    assert Floki.find(
             document,
             ~s(button[phx-click="react_to_post"][phx-value-emoji="🔥"][phx-value-message_id="#{original.id}"])
           ) != []

    assert Floki.find(
             document,
             ~s(button[phx-click="react_to_post"][phx-value-emoji="🔥"][phx-value-post_id="#{original.id}"])
           ) == []

    html = render_hook(view, "like_post", %{"message_id" => Integer.to_string(original.id)})
    assert Repo.get(Message, original.id).like_count == 1
    assert html =~ ~s(phx-click="unlike_post")
    assert html =~ ~s(data-count="1")

    html = render_hook(view, "boost_post", %{"message_id" => Integer.to_string(original.id)})
    assert Repo.get(Message, original.id).share_count == 2
    assert html =~ ~s(phx-click="unboost_post")
    assert html =~ ~s(data-count="2")

    html =
      render_hook(view, "react_to_post", %{
        "message_id" => Integer.to_string(original.id),
        "emoji" => "🔥"
      })

    assert Repo.get_by(Elektrine.Social.MessageReaction,
             message_id: original.id,
             user_id: viewer.id,
             emoji: "🔥"
           )

    assert html =~ "🔥"
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
      e_nav_badge_counts: nil,
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

  test "partial remote reply cache does not keep saying comments are importing" do
    local_message = %{
      id: 54_323,
      activitypub_id: "https://remote.example/posts/partial-comments",
      activitypub_url: "https://remote.example/posts/partial-comments",
      sender: nil,
      title: "Partial comments",
      content: "Post body",
      post_type: nil,
      poll: nil,
      quoted_message_id: nil,
      quoted_message: nil,
      media_urls: [],
      media_metadata: %{},
      primary_url: nil,
      link_preview: nil,
      like_count: 0,
      reply_count: 4,
      share_count: 0,
      upvotes: 0,
      downvotes: 0,
      score: 0,
      inserted_at: ~N[2026-02-25 03:31:05]
    }

    assigns = %{
      __changed__: %{},
      e_nav_badge_counts: nil,
      z: %{},
      loading: false,
      load_error: nil,
      is_local_post: false,
      local_message: local_message,
      post: %{
        "id" => "https://remote.example/posts/partial-comments",
        "type" => "Note",
        "content" => "Post body",
        "published" => "2026-02-25T03:31:05Z",
        "replies" => %{"totalItems" => 4},
        "attributedTo" => "https://remote.example/users/alice"
      },
      remote_actor: %{
        username: "alice",
        domain: "remote.example",
        display_name: "Alice",
        avatar_url: nil,
        uri: "https://remote.example/users/alice"
      },
      community_actor: nil,
      community_stats: %{members: 0, posts: 0},
      is_community_post: false,
      is_following_community: false,
      is_pending_community: false,
      is_following_author: false,
      is_pending_author: false,
      user_follows: %{},
      pending_follows: %{},
      remote_follow_overrides: %{},
      replies: [%{"id" => "https://remote.example/comments/1", "content" => "cached"}],
      threaded_replies: [],
      thread_reply_actors: %{},
      replies_loading: false,
      replies_loaded: true,
      reply_sync_checked: true,
      comment_sort: "hot",
      post_interactions: %{},
      user_saves: %{},
      lemmy_counts: nil,
      lemmy_comment_counts: %{},
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
      pending_remote_poll_vote: nil,
      in_reply_to: nil,
      reply_parent: nil,
      reply_parent_actor: nil,
      reply_ancestors: [],
      current_user: nil,
      platform_counts_load_ref: nil
    }

    html = assigns |> Show.render() |> rendered_to_string()

    refute html =~ "Importing comments from the remote thread"
    assert html =~ "3 comments are reported by the remote server but not cached here yet"
    assert html =~ "Retry import"
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
