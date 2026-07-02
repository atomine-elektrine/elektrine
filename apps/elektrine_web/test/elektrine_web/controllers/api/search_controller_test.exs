defmodule ElektrineWeb.API.SearchControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social
  alias ElektrineWeb.API.SearchController

  describe "index/2" do
    test "returns account, status, and hashtag buckets", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{username: "kairosearcher"})
      follower = user_fixture()
      followed = user_fixture()
      {:ok, target} = Accounts.update_user_display_name(target, "Kairo Searcher")
      assert {:ok, _follow} = Profiles.follow_user(follower.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(target.id, followed.id)
      assert {:ok, _target_post} = Social.create_timeline_post(target.id, "profile counter only")

      author = user_fixture()

      assert {:ok, post} =
               Social.create_timeline_post(author.id, "launching #kairosearch now",
                 visibility: "public"
               )

      conn =
        conn
        |> assign(:current_user, viewer)
        |> SearchController.index(%{"q" => "kairosearch"})

      assert %{
               "accounts" => [
                 %{
                   "id" => account_id,
                   "display_name" => "Kairo Searcher",
                   "followers_count" => 1,
                   "following_count" => 1,
                   "statuses_count" => 1
                 }
               ],
               "statuses" => [%{"id" => status_id, "content" => "launching #kairosearch now"}],
               "hashtags" => [%{"name" => "kairosearch"}]
             } = json_response(conn, 200)

      assert account_id == to_string(target.id)
      assert status_id == to_string(post.id)
    end

    test "supports type filtering", %{conn: conn} do
      viewer = user_fixture()
      author = user_fixture()

      assert {:ok, _post} =
               Social.create_timeline_post(author.id, "typed #onlytag result",
                 visibility: "public"
               )

      conn =
        conn
        |> assign(:current_user, viewer)
        |> SearchController.index(%{"q" => "onlytag", "type" => "hashtags"})

      assert %{
               "accounts" => [],
               "statuses" => [],
               "hashtags" => [%{"name" => "onlytag"}]
             } = json_response(conn, 200)
    end

    test "returns empty buckets for blank queries", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> SearchController.index(%{"q" => " "})

      assert %{"accounts" => [], "statuses" => [], "hashtags" => []} = json_response(conn, 200)
    end

    test "filters account search by privacy and relationship policy", %{conn: conn} do
      viewer = user_fixture()
      _private = user_fixture(%{username: "policysearchprivate", profile_visibility: "private"})
      muted = user_fixture(%{username: "policysearchmuted"})
      blocked_actor = remote_actor_fixture("policysearchremote", "blocked.example")

      assert {:ok, _mute} = Accounts.mute_user(viewer.id, muted.id)
      assert {:ok, _block} = Accounts.block_domain(viewer.id, "blocked.example")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> SearchController.index(%{"q" => "policysearch", "type" => "accounts"})

      assert %{"accounts" => accounts, "statuses" => [], "hashtags" => []} =
               json_response(conn, 200)

      account_ids = Enum.map(accounts, & &1["id"])

      refute to_string(muted.id) in account_ids
      refute "remote:#{blocked_actor.id}" in account_ids
      assert accounts == []
    end
  end

  defp remote_actor_fixture(username, domain) do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: username,
      summary: "",
      inbox_url: "https://#{domain}/inbox",
      outbox_url: "https://#{domain}/users/#{username}/outbox",
      public_key: "test-public-key-#{unique}",
      actor_type: "Person",
      manually_approves_followers: false,
      metadata: %{}
    })
    |> Repo.insert!()
  end
end
