defmodule ElektrineWeb.API.StatusActionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Ecto.Query
  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Message
  alias Elektrine.Social.ThreadMutes
  alias ElektrineWeb.API.StatusActionController

  describe "create/2" do
    test "creates a public status for the current user", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.create(%{
          "status" => "hello from the client api",
          "visibility" => "public",
          "spoiler_text" => "heads up",
          "sensitive" => "true"
        })

      assert %{
               "id" => id,
               "content" => "hello from the client api",
               "visibility" => "public",
               "spoiler_text" => "heads up",
               "sensitive" => true,
               "account" => %{"id" => user_id}
             } = json_response(conn, 201)

      assert user_id == to_string(user.id)
      post = Repo.get!(Message, id)
      assert post.sender_id == user.id
      assert post.content_warning == "heads up"
      assert post.sensitive
    end

    test "creates a reply status", %{conn: conn} do
      user = user_fixture()
      parent = post_fixture(%{visibility: "public", content: "parent"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.create(%{
          "status" => "reply from api",
          "visibility" => "public",
          "in_reply_to_id" => to_string(parent.id)
        })

      assert %{"id" => id, "in_reply_to_id" => parent_id} = json_response(conn, 201)
      assert parent_id == to_string(parent.id)
      assert Repo.get!(Message, id).reply_to_id == parent.id
    end

    test "creates a poll when poll options are provided", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.create(%{
          "status" => "pick one",
          "visibility" => "public",
          "poll" => %{
            "options" => ["one", "two"],
            "multiple" => "false",
            "expires_in" => "3600"
          }
        })

      assert %{
               "id" => id,
               "poll" => %{
                 "multiple" => false,
                 "options" => [%{"title" => "one"}, %{"title" => "two"}]
               }
             } = json_response(conn, 201)

      created = Repo.get!(Message, id) |> Repo.preload(poll: [:options])
      assert {:ok, poll} = Social.get_poll(created.poll.id)
      assert poll.question == "pick one"
    end

    test "delegates scheduled status creation when scheduled_at is provided", %{conn: conn} do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now()
        |> DateTime.add(600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.create(%{
          "status" => "post later",
          "visibility" => "followers",
          "scheduled_at" => scheduled_at
        })

      assert %{
               "id" => id,
               "scheduled_at" => ^scheduled_at,
               "params" => %{"text" => "post later", "visibility" => "followers"}
             } = json_response(conn, 201)

      scheduled = Repo.get!(Message, id)
      assert scheduled.sender_id == user.id
      assert scheduled.is_draft
      assert scheduled.scheduled_at
    end

    test "rejects an empty status without media", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.create(%{"status" => ""})

      assert %{"errors" => %{"errors" => %{"content" => ["must have either content or media"]}}} =
               json_response(conn, 422)
    end
  end

  describe "favourite/2 and unfavourite/2" do
    test "toggles the current user's favourite state", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.favourite(%{"id" => to_string(post.id)})

      assert %{"favourited" => true, "favourites_count" => 1} = json_response(conn, 200)
      assert Social.user_liked_post?(user.id, post.id)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusActionController.unfavourite(%{"id" => to_string(post.id)})

      assert %{"favourited" => false, "favourites_count" => 0} = json_response(conn, 200)
      refute Social.user_liked_post?(user.id, post.id)
    end
  end

  describe "reblog/2 and unreblog/2" do
    test "toggles the current user's reblog state", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.reblog(%{"id" => to_string(post.id)})

      assert %{"reblogged" => true, "reblogs_count" => 1} = json_response(conn, 200)
      assert Social.user_boosted?(user.id, post.id)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusActionController.unreblog(%{"id" => to_string(post.id)})

      assert %{"reblogged" => false, "reblogs_count" => 0} = json_response(conn, 200)
      refute Social.user_boosted?(user.id, post.id)
    end
  end

  describe "bookmark/2 and unbookmark/2" do
    test "toggles the current user's bookmark state", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.bookmark(%{"id" => to_string(post.id)})

      assert %{"bookmarked" => true} = json_response(conn, 200)
      assert Social.post_saved?(user.id, post.id)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusActionController.unbookmark(%{"id" => to_string(post.id)})

      assert %{"bookmarked" => false} = json_response(conn, 200)
      refute Social.post_saved?(user.id, post.id)
    end
  end

  describe "mute/2 and unmute/2" do
    test "toggles the current user's thread mute state", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.mute(%{"id" => to_string(post.id)})

      assert %{"muted" => true} = json_response(conn, 200)
      assert ThreadMutes.muted?(user.id, post)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusActionController.unmute(%{"id" => to_string(post.id)})

      assert %{"muted" => false} = json_response(conn, 200)
      refute ThreadMutes.muted?(user.id, post)
    end
  end

  describe "translate/2" do
    test "returns no-op translation metadata for a status", %{conn: conn} do
      user = user_fixture()

      post =
        post_fixture(%{
          visibility: "public",
          content: "bonjour"
        })

      {1, _} =
        Message
        |> where([message], message.id == ^post.id)
        |> Repo.update_all(
          set: [
            content_warning: "salut",
            media_metadata: %{
              "language" => "fr",
              "attachments" => [
                %{"id" => "image-1", "description" => "une image"}
              ]
            }
          ]
        )

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.translate(%{"id" => to_string(post.id), "lang" => "en"})

      assert %{
               "content" => "bonjour",
               "spoiler_text" => "salut",
               "detected_source_language" => "fr",
               "target_language" => "en",
               "provider" => "none",
               "poll" => nil,
               "media_attachments" => [%{"id" => "image-1", "description" => "une image"}]
             } = json_response(conn, 200)
    end
  end

  describe "update/2" do
    test "edits the current user's status", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public", content: "old"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.update(%{"id" => to_string(post.id), "status" => "new"})

      assert %{"id" => id, "content" => "new"} = json_response(conn, 200)
      assert id == to_string(post.id)

      updated = Repo.get!(Message, post.id)
      assert updated.content == "new"
      assert updated.edited_at
    end

    test "does not edit another user's status", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      post = post_fixture(%{user: other, visibility: "public", content: "old"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.update(%{"id" => to_string(post.id), "status" => "new"})

      assert %{"error" => "not found"} = json_response(conn, 404)
      assert Repo.get!(Message, post.id).content == "old"
    end
  end

  describe "delete/2" do
    test "deletes the current user's status", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{user: user, visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.delete(%{"id" => to_string(post.id)})

      assert %{"id" => id} = json_response(conn, 200)
      assert id == to_string(post.id)
      assert Repo.get!(Message, post.id).deleted_at
    end

    test "does not delete another user's status", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      post = post_fixture(%{user: other, visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusActionController.delete(%{"id" => to_string(post.id)})

      assert %{"error" => "not found"} = json_response(conn, 404)
      refute Repo.get!(Message, post.id).deleted_at
    end
  end

  test "returns not found for missing statuses", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> assign(:current_user, user)
      |> StatusActionController.favourite(%{"id" => "-1"})

    assert %{"error" => "not found"} = json_response(conn, 404)
  end
end
