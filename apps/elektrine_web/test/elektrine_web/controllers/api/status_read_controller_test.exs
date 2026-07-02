defmodule ElektrineWeb.API.StatusReadControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.BookmarkFolders
  alias Elektrine.Social.Message
  alias Elektrine.Social.ThreadMutes
  alias ElektrineWeb.API.StatusReadController

  describe "index/2" do
    test "returns visible statuses in requested order and skips hidden or invalid ids", %{
      conn: conn
    } do
      viewer = user_fixture()
      owner = user_fixture()
      first = post_fixture(%{visibility: "public", content: "first"})
      second = post_fixture(%{visibility: "public", content: "second"})
      muted_author = user_fixture()
      hidden = post_fixture(%{user: owner, visibility: "private", content: "hidden"})
      muted = post_fixture(%{user: muted_author, visibility: "public", content: "muted"})

      assert {:ok, _mute} = Accounts.mute_user(viewer.id, muted_author.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.index(%{
          "id[]" => [
            to_string(second.id),
            "bad",
            to_string(hidden.id),
            to_string(muted.id),
            to_string(first.id),
            to_string(second.id)
          ]
        })

      assert [
               %{"id" => second_id, "content" => "second"},
               %{"id" => first_id, "content" => "first"}
             ] = json_response(conn, 200)

      assert second_id == to_string(second.id)
      assert first_id == to_string(first.id)
    end

    test "supports comma-separated ids", %{conn: conn} do
      viewer = user_fixture()
      first = post_fixture(%{visibility: "public", content: "first"})
      second = post_fixture(%{visibility: "public", content: "second"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.index(%{"id" => "#{first.id},#{second.id},not-a-number"})

      assert [
               %{"id" => first_id},
               %{"id" => second_id}
             ] = json_response(conn, 200)

      assert first_id == to_string(first.id)
      assert second_id == to_string(second.id)
    end
  end

  describe "show/2" do
    test "returns a visible status", %{conn: conn} do
      viewer = user_fixture()
      post = post_fixture(%{visibility: "public", content: "visible status"})
      other_user = user_fixture()

      assert {:ok, _reaction} = Social.add_status_reaction(viewer.id, post.id, "zap")
      assert {:ok, _reaction} = Social.add_status_reaction(other_user.id, post.id, "zap")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{
               "id" => id,
               "content" => "visible status",
               "visibility" => "public",
               "favourited" => false,
               "reblogged" => false,
               "bookmarked" => false,
               "emoji_reactions" => [%{"name" => "zap", "count" => 2, "me" => true}]
             } = json_response(conn, 200)

      assert id == to_string(post.id)
    end

    test "embeds canonical status URLs and extension metadata", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      quoted = post_fixture(%{user: author, visibility: "public", content: "quoted source"})
      {:ok, quote} = Social.create_quote_post(author.id, quoted.id, "quoted status")
      assert {:ok, pinned} = Social.pin_timeline_post(author.id, quote.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(pinned.id)})

      assert %{
               "id" => id,
               "uri" => uri,
               "url" => url,
               "in_quote_to_id" => quoted_id,
               "pleroma" => %{
                 "local" => true,
                 "conversation_id" => conversation_id,
                 "quote_id" => quoted_id,
                 "quote_url" => quote_url,
                 "quote_visible" => true,
                 "pinned_at" => pinned_at,
                 "quotes_count" => 0
               }
             } = json_response(conn, 200)

      assert id == to_string(pinned.id)
      assert uri == url
      assert url in [pinned.activitypub_url, ElektrineWeb.Endpoint.url() <> "/post/#{pinned.id}"]
      assert conversation_id == to_string(pinned.conversation_id)
      assert quoted_id == to_string(quoted.id)

      assert quote_url in [
               quoted.activitypub_url,
               ElektrineWeb.Endpoint.url() <> "/post/#{quoted.id}"
             ]

      assert pinned_at
    end

    test "hides muted reactors from embedded reaction summaries", %{conn: conn} do
      viewer = user_fixture()
      muted_user = user_fixture()
      visible_user = user_fixture()
      post = post_fixture(%{visibility: "public", content: "reaction summary"})

      assert {:ok, _reaction} = Social.add_status_reaction(muted_user.id, post.id, "zap")
      assert {:ok, _reaction} = Social.add_status_reaction(visible_user.id, post.id, "zap")
      assert {:ok, _mute} = Accounts.mute_user(viewer.id, muted_user.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      response = json_response(conn, 200)
      assert [%{"name" => "zap", "count" => 1, "me" => false}] = response["emoji_reactions"]
      assert response["pleroma"]["emoji_reactions"] == response["emoji_reactions"]
    end

    test "hides non-visible statuses", %{conn: conn} do
      viewer = user_fixture()
      owner = user_fixture()
      post = post_fixture(%{user: owner, visibility: "private"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "hides muted authors unless explicitly requested", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      post = post_fixture(%{user: author, visibility: "public", content: "muted status"})

      assert {:ok, _mute} = Accounts.mute_user(viewer.id, author.id)

      hidden_conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{"error" => "not found"} = json_response(hidden_conn, 404)

      visible_conn =
        Phoenix.ConnTest.build_conn()
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id), "with_muted" => "true"})

      assert %{"id" => id, "content" => "muted status", "muted" => true} =
               json_response(visible_conn, 200)

      assert id == to_string(post.id)
    end

    test "marks muted threads in status JSON", %{conn: conn} do
      viewer = user_fixture()
      post = post_fixture(%{visibility: "public", content: "thread mute status"})

      assert {:ok, _mute} = ThreadMutes.mute_thread(viewer.id, post)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{
               "id" => id,
               "muted" => true,
               "pleroma" => %{"thread_muted" => true}
             } = json_response(conn, 200)

      assert id == to_string(post.id)
    end

    test "embeds stored status metadata for compatible clients", %{conn: conn} do
      viewer = user_fixture()
      post = post_fixture(%{visibility: "public", content: "metadata status"})

      {:ok, post} =
        post
        |> Ecto.Changeset.change(%{
          content_warning: "metadata cw",
          edited_at: ~U[2026-07-01 12:00:00Z],
          extracted_hashtags: ["Elixir", "#Phoenix"],
          media_metadata: %{
            "application" => %{"name" => "FedDesk", "url" => "https://apps.example/feddesk"},
            "card" => %{"url" => "https://example.com/story", "title" => "Story"},
            "emoji" => %{"blob" => "https://cdn.example/blob.png"},
            "expires_at" => "2026-07-03T12:00:00Z",
            "language" => "fr"
          }
        })
        |> Repo.update()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{
               "id" => id,
               "edited_at" => edited_at,
               "language" => "fr",
               "application" => %{
                 "name" => "FedDesk",
                 "website" => "https://apps.example/feddesk"
               },
               "card" => %{"url" => "https://example.com/story", "title" => "Story"},
               "emojis" => [
                 %{
                   "shortcode" => "blob",
                   "url" => "https://cdn.example/blob.png",
                   "static_url" => "https://cdn.example/blob.png",
                   "visible_in_picker" => false
                 }
               ],
               "mentions" => [],
               "tags" => tags,
               "pleroma" => %{
                 "content" => %{"text/plain" => "metadata status"},
                 "spoiler_text" => %{"text/plain" => "metadata cw"},
                 "expires_at" => "2026-07-03T12:00:00Z",
                 "thread_muted" => false,
                 "visible_reactions" => true
               }
             } = json_response(conn, 200)

      assert id == to_string(post.id)
      assert edited_at == "2026-07-01T12:00:00Z"
      assert Enum.map(tags, & &1["name"]) == ["Elixir", "Phoenix"]
    end

    test "embeds the current user's bookmark folder in status JSON", %{conn: conn} do
      viewer = user_fixture()
      post = post_fixture(%{visibility: "public", content: "folder status"})

      {:ok, folder} =
        BookmarkFolders.create_folder(viewer.id, %{"name" => "Queue", "emoji" => "Q"})

      assert {:ok, _saved} = Social.save_post(viewer.id, post.id, bookmark_folder_id: folder.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{
               "bookmarked" => true,
               "pleroma" => %{
                 "bookmark_folder" => folder_id
               }
             } = json_response(conn, 200)

      assert folder_id == folder.id
    end

    test "embeds poll data in status JSON", %{conn: conn} do
      author = user_fixture()
      viewer = user_fixture()
      post = post_fixture(%{user: author, visibility: "public", content: "poll status"})
      {:ok, poll} = Social.create_poll(post.id, "Pick one", ["One", "Two"])
      [option, _] = poll.options
      assert {:ok, _poll} = Social.set_poll_votes(poll.id, [option.id], viewer.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.show(%{"id" => to_string(post.id)})

      assert %{
               "poll" => %{
                 "id" => poll_id,
                 "multiple" => false,
                 "voted" => true,
                 "own_votes" => [option_id],
                 "votes_count" => 1,
                 "options" => [
                   %{"title" => "One", "votes_count" => 1},
                   %{"title" => "Two", "votes_count" => 0}
                 ]
               }
             } = json_response(conn, 200)

      assert poll_id == to_string(poll.id)
      assert option_id == to_string(option.id)
    end
  end

  describe "context/2" do
    test "returns visible ancestors and descendants", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      root = post_fixture(%{user: author, visibility: "public", content: "root"})
      child = reply_fixture(root, %{user: author, content: "child"})
      grandchild = reply_fixture(child, %{user: author, content: "grandchild"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.context(%{"id" => to_string(child.id)})

      assert %{"ancestors" => ancestors, "descendants" => descendants} = json_response(conn, 200)
      assert Enum.map(ancestors, & &1["id"]) == [to_string(root.id)]
      assert Enum.map(descendants, & &1["id"]) == [to_string(grandchild.id)]
    end
  end

  describe "favourited_by/2" do
    test "lists local accounts that favourited a visible status", %{conn: conn} do
      viewer = user_fixture()
      liker = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, _like} = Social.like_post(liker.id, post.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.favourited_by(%{"id" => to_string(post.id)})

      assert [%{"id" => liker_id, "username" => username}] = json_response(conn, 200)
      assert liker_id == to_string(liker.id)
      assert username == liker.username
    end
  end

  describe "reblogged_by/2" do
    test "lists local accounts that reblogged a visible status", %{conn: conn} do
      viewer = user_fixture()
      booster = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, _boost} = Social.boost_post(booster.id, post.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.reblogged_by(%{"id" => to_string(post.id)})

      assert [%{"id" => booster_id, "username" => username}] = json_response(conn, 200)
      assert booster_id == to_string(booster.id)
      assert username == booster.username
    end
  end

  describe "quotes/2" do
    test "serves the prefixed client-compatible route", %{conn: conn} do
      viewer = user_fixture()
      quoter = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, quote} = Social.create_quote_post(quoter.id, post.id, "prefixed quote")
      {:ok, token} = ElektrineWeb.Plugs.APIAuth.generate_token(viewer.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/pleroma/statuses/#{post.id}/quotes")

      assert [%{"id" => quote_id, "content" => "prefixed quote"}] = json_response(conn, 200)
      assert quote_id == to_string(quote.id)
    end

    test "lists visible quote posts", %{conn: conn} do
      viewer = user_fixture()
      quoter = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, quote} = Social.create_quote_post(quoter.id, post.id, "quoted with context")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.quotes(%{"id" => to_string(post.id)})

      assert [
               %{
                 "id" => quote_id,
                 "content" => "quoted with context",
                 "in_quote_to_id" => quoted_id
               }
             ] =
               json_response(conn, 200)

      assert quote_id == to_string(quote.id)
      assert quoted_id == to_string(post.id)
    end
  end

  describe "source/2" do
    test "returns source text for the status owner", %{conn: conn} do
      author = user_fixture()
      post = post_fixture(%{user: author, visibility: "public", content: "source text"})

      conn =
        conn
        |> assign(:current_user, author)
        |> StatusReadController.source(%{"id" => to_string(post.id)})

      assert %{"id" => id, "text" => "source text", "spoiler_text" => ""} =
               json_response(conn, 200)

      assert id == to_string(post.id)
    end

    test "does not expose source text to other users", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      post = post_fixture(%{user: author, visibility: "public", content: "source text"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.source(%{"id" => to_string(post.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  describe "history/2" do
    test "returns former representations plus the current version", %{conn: conn} do
      viewer = user_fixture()
      post = post_fixture(%{visibility: "public", content: "current"})

      {:ok, edited} =
        post
        |> Ecto.Changeset.change(%{
          edited_at: ~U[2026-07-01 10:00:00Z],
          media_metadata: %{
            "formerRepresentations" => %{
              "type" => "OrderedCollection",
              "orderedItems" => [
                %{
                  "type" => "Note",
                  "content" => "previous",
                  "summary" => "old cw",
                  "updated" => "2026-07-01T09:00:00Z"
                }
              ]
            }
          }
        })
        |> Repo.update()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> StatusReadController.history(%{"id" => to_string(edited.id)})

      assert [
               %{"content" => "previous", "spoiler_text" => "old cw"},
               %{"content" => "current", "spoiler_text" => ""}
             ] = json_response(conn, 200)
    end
  end

  defp reply_fixture(parent, attrs) do
    user = attrs[:user] || user_fixture()
    content = attrs[:content] || "reply #{System.unique_integer([:positive])}"

    {:ok, message} =
      %Message{}
      |> Message.changeset(%{
        conversation_id: parent.conversation_id,
        sender_id: user.id,
        reply_to_id: parent.id,
        content: content,
        message_type: "text",
        visibility: attrs[:visibility] || "public",
        post_type: "post",
        like_count: 0,
        reply_count: 0,
        share_count: 0
      })
      |> Repo.insert()

    message |> Repo.preload([:sender, :conversation])
  end
end
