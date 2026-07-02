defmodule ElektrineWeb.API.ListControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.List
  alias Elektrine.Social.ListMember
  alias ElektrineWeb.API.ListController

  describe "list CRUD" do
    test "creates, lists, updates, shows, and deletes current user's lists", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> ListController.create(%{
          "title" => "Launch radar",
          "description" => "People shipping useful things",
          "visibility" => "private"
        })

      assert %{
               "id" => id,
               "title" => "Launch radar",
               "description" => "People shipping useful things",
               "visibility" => "private",
               "accounts_count" => 0,
               "pleroma" => %{"emoji" => nil, "emoji_url" => nil}
             } = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> ListController.index(%{})

      assert [%{"id" => ^id, "title" => "Launch radar"}] = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> ListController.update(%{
          "id" => id,
          "title" => "Release radar",
          "visibility" => "public"
        })

      assert %{"id" => ^id, "title" => "Release radar", "visibility" => "public"} =
               json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> ListController.show(%{"id" => id})

      assert %{"id" => ^id, "title" => "Release radar"} = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> ListController.delete(%{"id" => id})

      assert %{} = json_response(conn, 200)
      refute Repo.get(List, id)
    end

    test "does not expose another user's list", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()

      {:ok, list} =
        Social.create_list(%{user_id: owner.id, name: "Private", visibility: "private"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> ListController.show(%{"id" => list.id})

      assert %{"error" => "list not found"} = json_response(conn, 404)
    end
  end

  describe "list accounts" do
    test "adds, lists, idempotently re-adds, and removes accounts", %{conn: conn} do
      owner = user_fixture()
      member = user_fixture(%{username: "listmember"})

      {:ok, list} =
        Social.create_list(%{user_id: owner.id, name: "Members", visibility: "private"})

      conn =
        conn
        |> assign(:current_user, owner)
        |> ListController.add_accounts(%{
          "id" => list.id,
          "account_ids" => [to_string(member.id)]
        })

      assert %{"id" => id, "accounts_count" => 1} = json_response(conn, 200)
      assert id == to_string(list.id)

      conn =
        build_conn()
        |> assign(:current_user, owner)
        |> ListController.add_accounts(%{
          "id" => list.id,
          "account_ids" => [to_string(member.id)]
        })

      assert %{"accounts_count" => 1} = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, owner)
        |> ListController.accounts(%{"id" => list.id})

      assert [%{"id" => member_id, "username" => "listmember", "remote" => false}] =
               json_response(conn, 200)

      assert member_id == to_string(member.id)

      conn =
        build_conn()
        |> assign(:current_user, owner)
        |> ListController.remove_accounts(%{
          "id" => list.id,
          "account_ids" => [to_string(member.id)]
        })

      assert %{"accounts_count" => 0} = json_response(conn, 200)
      assert Repo.aggregate(ListMember, :count) == 0
    end

    test "does not mutate another user's list", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()
      member = user_fixture()
      {:ok, list} = Social.create_list(%{user_id: owner.id, name: "Owned", visibility: "private"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> ListController.add_accounts(%{
          "id" => list.id,
          "account_ids" => [to_string(member.id)]
        })

      assert %{"error" => "list not found"} = json_response(conn, 404)
      assert Repo.aggregate(ListMember, :count) == 0
    end
  end

  describe "list timeline" do
    test "lists statuses from list members only", %{conn: conn} do
      owner = user_fixture()
      member = user_fixture(%{username: "timelinemember"})
      non_member = user_fixture(%{username: "notlisted"})

      {:ok, list} =
        Social.create_list(%{user_id: owner.id, name: "Timeline", visibility: "private"})

      assert {:ok, _members} =
               Social.add_accounts_to_list(owner.id, list.id, %{
                 "account_ids" => [to_string(member.id)]
               })

      member_post = post_fixture(%{user: member, content: "member post"})
      _non_member_post = post_fixture(%{user: non_member, content: "non-member post"})

      conn =
        conn
        |> assign(:current_user, owner)
        |> ListController.timeline(%{"id" => to_string(list.id)})

      assert [%{"id" => id, "content" => "member post"}] = json_response(conn, 200)
      assert id == to_string(member_post.id)
    end

    test "does not expose another user's list timeline", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()
      member = user_fixture()

      {:ok, list} =
        Social.create_list(%{user_id: owner.id, name: "Private", visibility: "private"})

      assert {:ok, _members} =
               Social.add_accounts_to_list(owner.id, list.id, %{
                 "account_ids" => [to_string(member.id)]
               })

      _post = post_fixture(%{user: member, content: "private list post"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> ListController.timeline(%{"id" => to_string(list.id)})

      assert %{"error" => "list not found"} = json_response(conn, 404)
    end

    test "supports max_id pagination with link headers" do
      owner = user_fixture()
      member = user_fixture()

      {:ok, list} =
        Social.create_list(%{user_id: owner.id, name: "Timeline", visibility: "private"})

      assert {:ok, _members} =
               Social.add_accounts_to_list(owner.id, list.id, %{
                 "account_ids" => [to_string(member.id)]
               })

      older = post_fixture(%{user: member, content: "older list post"})
      newer = post_fixture(%{user: member, content: "newer list post"})

      conn =
        build_conn(:get, "/api/v1/timelines/list/#{list.id}?limit=1")
        |> assign(:current_user, owner)
        |> ListController.timeline(%{
          "id" => to_string(list.id),
          "limit" => "1",
          "max_id" => to_string(newer.id)
        })

      assert [%{"id" => id, "content" => "older list post"}] = json_response(conn, 200)
      assert id == to_string(older.id)

      assert [link] = get_resp_header(conn, "link")
      assert link =~ "/api/v1/timelines/list/#{list.id}?limit=1&max_id=#{older.id}"
      assert link =~ "/api/v1/timelines/list/#{list.id}?limit=1&since_id=#{older.id}"
    end
  end
end
