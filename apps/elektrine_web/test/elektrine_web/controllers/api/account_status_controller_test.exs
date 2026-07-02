defmodule ElektrineWeb.API.AccountStatusControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Social
  alias ElektrineWeb.API.AccountStatusController

  describe "index/2" do
    test "lists visible account statuses", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      public_post = post_fixture(%{user: author, visibility: "public", content: "public"})
      _private_post = post_fixture(%{user: author, visibility: "private", content: "private"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{"id" => to_string(author.id)})

      assert [%{"id" => id, "content" => "public"}] = json_response(conn, 200)
      assert id == to_string(public_post.id)
    end

    test "returns pinned statuses only when requested", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      pinned = post_fixture(%{user: author, visibility: "public", content: "pinned"})
      _regular = post_fixture(%{user: author, visibility: "public", content: "regular"})

      assert {:ok, _pinned} = Social.pin_timeline_post(author.id, pinned.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{"id" => to_string(author.id), "pinned" => "true"})

      assert [%{"id" => id, "pinned" => true, "content" => "pinned"}] = json_response(conn, 200)
      assert id == to_string(pinned.id)
    end

    test "filters media statuses", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      media = media_post_fixture(%{user: author, media_urls: ["/uploads/photo.jpg"]})
      _text = post_fixture(%{user: author, visibility: "public"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{"id" => to_string(author.id), "only_media" => "true"})

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(media.id)
    end

    test "embeds poll data in account status lists", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      post = post_fixture(%{user: author, visibility: "public", content: "account poll"})
      {:ok, poll} = Social.create_poll(post.id, "Hidden?", ["Yes", "No"], hide_totals: true)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{"id" => to_string(author.id)})

      assert [
               %{
                 "id" => id,
                 "poll" => %{
                   "id" => poll_id,
                   "votes_count" => nil,
                   "voters_count" => nil,
                   "options" => [%{"votes_count" => nil}, %{"votes_count" => nil}]
                 }
               }
             ] = json_response(conn, 200)

      assert id == to_string(post.id)
      assert poll_id == to_string(poll.id)
    end

    test "filters boosts", %{conn: conn} do
      viewer = user_fixture()
      booster = user_fixture()
      original = post_fixture(%{visibility: "public"})
      regular = post_fixture(%{user: booster, visibility: "public"})

      assert {:ok, _boost} = Social.boost_post(booster.id, original.id)

      only_reblogs_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{
          "id" => to_string(booster.id),
          "only_reblogs" => "true"
        })

      assert [
               %{
                 "reblogged" => false,
                 "reblog" => %{
                   "id" => original_id,
                   "content" => original_content,
                   "reblog" => nil
                 }
               } = boosted_status
             ] = json_response(only_reblogs_conn, 200)

      refute boosted_status["id"] == to_string(regular.id)
      assert original_id == to_string(original.id)
      assert original_content == original.content

      exclude_reblogs_conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{
          "id" => to_string(booster.id),
          "exclude_reblogs" => "true"
        })

      assert [%{"id" => id}] = json_response(exclude_reblogs_conn, 200)
      assert id == to_string(regular.id)
    end

    test "supports limit and max_id pagination", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()
      older = post_fixture(%{user: author, visibility: "public", content: "older"})
      newer = post_fixture(%{user: author, visibility: "public", content: "newer"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{
          "id" => to_string(author.id),
          "limit" => "1",
          "max_id" => to_string(newer.id)
        })

      assert [%{"id" => id, "content" => "older"}] = json_response(conn, 200)
      assert id == to_string(older.id)
    end

    test "returns 404 for a missing account", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.index(%{"id" => "-1"})

      assert %{"error" => "account not found"} = json_response(conn, 404)
    end
  end

  describe "favourites/2" do
    test "serves the prefixed client-compatible route", %{conn: conn} do
      viewer = user_fixture()
      account = user_fixture()
      post = post_fixture(%{visibility: "public", content: "prefixed liked"})

      assert {:ok, _like} = Social.like_post(account.id, post.id)
      {:ok, token} = ElektrineWeb.Plugs.APIAuth.generate_token(viewer.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/pleroma/accounts/#{account.id}/favourites")

      assert [%{"id" => id, "content" => "prefixed liked"}] = json_response(conn, 200)
      assert id == to_string(post.id)
    end

    test "lists visible statuses favourited by the account", %{conn: conn} do
      viewer = user_fixture()
      account = user_fixture()
      older = post_fixture(%{visibility: "public", content: "older liked"})
      newer = post_fixture(%{visibility: "public", content: "newer liked"})
      _unliked = post_fixture(%{visibility: "public", content: "not liked"})

      assert {:ok, _like} = Social.like_post(account.id, older.id)
      assert {:ok, _like} = Social.like_post(account.id, newer.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.favourites(%{"id" => to_string(account.id)})

      assert [
               %{"id" => newer_id, "content" => "newer liked", "favourited" => false},
               %{"id" => older_id, "content" => "older liked", "favourited" => false}
             ] = json_response(conn, 200)

      assert newer_id == to_string(newer.id)
      assert older_id == to_string(older.id)
    end

    test "supports search filtering", %{conn: conn} do
      viewer = user_fixture()
      account = user_fixture()
      matching = post_fixture(%{visibility: "public", content: "needle liked"})
      other = post_fixture(%{visibility: "public", content: "plain liked"})

      assert {:ok, _like} = Social.like_post(account.id, matching.id)
      assert {:ok, _like} = Social.like_post(account.id, other.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.favourites(%{
          "id" => to_string(account.id),
          "q" => "needle"
        })

      assert [%{"id" => id, "content" => "needle liked"}] = json_response(conn, 200)
      assert id == to_string(matching.id)
    end

    test "does not expose private favourites hidden from the viewer", %{conn: conn} do
      viewer = user_fixture()
      account = user_fixture()
      public_post = post_fixture(%{user: account, visibility: "public", content: "visible liked"})

      private_post =
        post_fixture(%{user: account, visibility: "private", content: "hidden liked"})

      assert {:ok, _like} = Social.like_post(account.id, private_post.id)
      assert {:ok, _like} = Social.like_post(account.id, public_post.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.favourites(%{"id" => to_string(account.id)})

      assert [%{"id" => id, "content" => "visible liked"}] = json_response(conn, 200)
      assert id == to_string(public_post.id)
    end

    test "hides favourites from other users but not the owner", %{conn: conn} do
      viewer = user_fixture()
      account = user_fixture(%{hide_favorites: true})
      post = post_fixture(%{visibility: "public", content: "liked privately"})

      assert {:ok, _like} = Social.like_post(account.id, post.id)

      hidden_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountStatusController.favourites(%{"id" => to_string(account.id)})

      assert [] = json_response(hidden_conn, 200)

      owner_conn =
        build_conn()
        |> assign(:current_user, account)
        |> AccountStatusController.favourites(%{"id" => to_string(account.id)})

      assert [%{"id" => id, "content" => "liked privately"}] = json_response(owner_conn, 200)
      assert id == to_string(post.id)
    end
  end
end
