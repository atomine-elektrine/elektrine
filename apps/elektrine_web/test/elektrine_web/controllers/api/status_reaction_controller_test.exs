defmodule ElektrineWeb.API.StatusReactionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.Messaging
  alias Elektrine.Social
  alias ElektrineWeb.API.StatusReactionController

  describe "index/2" do
    test "lists grouped reactions and marks the current user's reaction", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, _reaction} = Social.add_status_reaction(user.id, post.id, "zap")
      assert {:ok, _reaction} = Social.add_status_reaction(other_user.id, post.id, "zap")

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusReactionController.index(%{"id" => to_string(post.id)})

      assert [
               %{
                 "name" => "zap",
                 "count" => 2,
                 "me" => true,
                 "accounts" => accounts
               }
             ] = json_response(conn, 200)

      assert Enum.map(accounts, & &1["id"]) |> Enum.sort() ==
               [to_string(user.id), to_string(other_user.id)] |> Enum.sort()
    end

    test "hides muted local reactors unless requested", %{conn: conn} do
      user = user_fixture()
      muted_user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, _reaction} = Social.add_status_reaction(muted_user.id, post.id, "zap")
      assert {:ok, _mute} = Accounts.mute_user(user.id, muted_user.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusReactionController.index(%{"id" => to_string(post.id)})

      assert [] = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusReactionController.index(%{"id" => to_string(post.id), "with_muted" => "true"})

      assert [%{"name" => "zap", "count" => 1}] = json_response(conn, 200)
    end
  end

  describe "show/2" do
    test "lists only the requested reaction name", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, _reaction} = Social.add_status_reaction(other_user.id, post.id, "zap")
      assert {:ok, _reaction} = Social.add_status_reaction(other_user.id, post.id, "spark")

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusReactionController.show(%{"id" => to_string(post.id), "emoji" => "spark"})

      assert [%{"name" => "spark", "count" => 1, "me" => false}] = json_response(conn, 200)
    end
  end

  describe "create/2" do
    test "adds reactions idempotently", %{conn: conn} do
      user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusReactionController.create(%{"id" => to_string(post.id), "emoji" => "zap"})

      response = json_response(conn, 200)
      assert response["id"] == to_string(post.id)
      assert response["account"]["id"] == to_string(post.sender_id)

      assert [%{"name" => "zap", "count" => 1, "me" => true, "url" => nil}] =
               response["emoji_reactions"]

      assert response["pleroma"]["emoji_reactions"] == response["emoji_reactions"]

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusReactionController.create(%{"id" => to_string(post.id), "emoji" => "zap"})

      assert %{"id" => post_id, "emoji_reactions" => reactions} = json_response(conn, 200)
      assert post_id == to_string(post.id)
      assert [%{"name" => "zap", "count" => 1, "me" => true}] = reactions
    end

    test "does not add reactions to hidden statuses", %{conn: conn} do
      user = user_fixture()
      owner = user_fixture()
      post = post_fixture(%{user: owner, visibility: "private"})

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusReactionController.create(%{"id" => to_string(post.id), "emoji" => "zap"})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  describe "delete/2" do
    test "removes the current user's reaction only", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      post = post_fixture(%{visibility: "public"})

      assert {:ok, _reaction} = Messaging.add_reaction(post.id, user.id, "zap")
      assert {:ok, _reaction} = Messaging.add_reaction(post.id, other_user.id, "zap")

      conn =
        conn
        |> assign(:current_user, user)
        |> StatusReactionController.delete(%{"id" => to_string(post.id), "emoji" => "zap"})

      assert %{"id" => post_id, "emoji_reactions" => reactions} = json_response(conn, 200)
      assert post_id == to_string(post.id)
      assert [%{"name" => "zap", "count" => 1, "me" => false}] = reactions

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> StatusReactionController.index(%{"id" => to_string(post.id)})

      assert [%{"name" => "zap", "count" => 1, "me" => false, "accounts" => [account]}] =
               json_response(conn, 200)

      assert account["id"] == to_string(other_user.id)
    end
  end
end
