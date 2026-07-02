defmodule ElektrineWeb.API.AccountRelationshipControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social
  alias ElektrineWeb.API.AccountRelationshipController

  describe "relationships/2" do
    test "returns relationship flags for multiple accounts", %{conn: conn} do
      viewer = user_fixture()
      followed = user_fixture()
      follower = user_fixture()
      muted = user_fixture()
      blocked = user_fixture()
      unrelated = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, followed.id)
      assert {:ok, _follow} = Profiles.follow_user(follower.id, viewer.id)
      assert {:ok, _mute} = Accounts.mute_user(viewer.id, muted.id, true)
      assert {:ok, _block} = Accounts.block_user(viewer.id, blocked.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.relationships(%{
          "id" => [
            to_string(followed.id),
            to_string(follower.id),
            to_string(muted.id),
            to_string(blocked.id),
            to_string(unrelated.id)
          ]
        })

      relationships =
        conn
        |> json_response(200)
        |> Map.new(&{&1["id"], &1})

      assert relationships[to_string(followed.id)]["following"] == true
      assert relationships[to_string(followed.id)]["followed_by"] == false

      assert relationships[to_string(follower.id)]["following"] == false
      assert relationships[to_string(follower.id)]["followed_by"] == true

      assert relationships[to_string(muted.id)]["muting"] == true
      assert relationships[to_string(muted.id)]["muting_notifications"] == true

      assert relationships[to_string(blocked.id)]["blocking"] == true

      assert relationships[to_string(unrelated.id)]["following"] == false
      assert relationships[to_string(unrelated.id)]["followed_by"] == false
      assert relationships[to_string(unrelated.id)]["muting"] == false
      assert relationships[to_string(unrelated.id)]["blocking"] == false
    end

    test "supports comma-separated ids and skips missing accounts", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.relationships(%{
          "id" => "#{target.id},-1,bad,#{target.id}"
        })

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(target.id)
    end

    test "reports remote domain blocks", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture("news.blocked.example")

      assert {:ok, _block} = Accounts.block_domain(viewer.id, "*.blocked.example")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.relationships(%{"id" => "remote:#{actor.id}"})

      assert [%{"id" => id, "domain_blocking" => true, "blocking" => false}] =
               json_response(conn, 200)

      assert id == to_string(actor.id)
    end

    test "includes private account notes for local and remote relationships", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      actor = remote_actor_fixture("noted.example")

      assert {:ok, _note} = Accounts.put_account_note(viewer.id, {:user, target.id}, "local note")

      assert {:ok, _note} =
               Accounts.put_account_note(viewer.id, {:remote_actor, actor.id}, "remote note")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.relationships(%{
          "id" => [to_string(target.id), "remote:#{actor.id}"]
        })

      relationships =
        conn
        |> json_response(200)
        |> Map.new(&{&1["id"], &1})

      assert relationships[to_string(target.id)]["note"] == "local note"
      assert relationships[to_string(actor.id)]["note"] == "remote note"
    end
  end

  describe "mutes/2 and blocks/2" do
    test "embeds relationships when requested", %{conn: conn} do
      viewer = user_fixture()
      muted = user_fixture(%{username: "embeddedmute"})
      blocked = user_fixture(%{username: "embeddedblock"})

      assert {:ok, _mute} = Accounts.mute_user(viewer.id, muted.id, true)
      assert {:ok, _block} = Accounts.block_user(viewer.id, blocked.id)

      mutes_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.mutes(%{"with_relationships" => "true"})

      assert [
               %{
                 "id" => muted_id,
                 "pleroma" => %{
                   "relationship" => %{
                     "muting" => true,
                     "muting_notifications" => true
                   }
                 }
               }
             ] = json_response(mutes_conn, 200)

      assert muted_id == to_string(muted.id)

      blocks_conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.blocks(%{"with_relationships" => "true"})

      assert [
               %{
                 "id" => blocked_id,
                 "pleroma" => %{"relationship" => %{"blocking" => true}}
               }
             ] = json_response(blocks_conn, 200)

      assert blocked_id == to_string(blocked.id)
    end
  end

  describe "followers/2 and following/2 privacy" do
    test "hides follower lists from other users but not the owner", %{conn: conn} do
      owner = user_fixture(%{hide_followers: true})
      follower = user_fixture()
      viewer = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(follower.id, owner.id)

      hidden_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.followers(%{"id" => to_string(owner.id)})

      assert [] = json_response(hidden_conn, 200)

      owner_conn =
        build_conn()
        |> assign(:current_user, owner)
        |> AccountRelationshipController.followers(%{"id" => to_string(owner.id)})

      assert [%{"id" => id}] = json_response(owner_conn, 200)
      assert id == to_string(follower.id)
    end

    test "hides following lists from other users but not the owner", %{conn: conn} do
      owner = user_fixture(%{hide_follows: true})
      followed = user_fixture()
      viewer = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(owner.id, followed.id)

      hidden_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.following(%{"id" => to_string(owner.id)})

      assert [] = json_response(hidden_conn, 200)

      owner_conn =
        build_conn()
        |> assign(:current_user, owner)
        |> AccountRelationshipController.following(%{"id" => to_string(owner.id)})

      assert [%{"id" => id}] = json_response(owner_conn, 200)
      assert id == to_string(followed.id)
    end
  end

  describe "lists/2" do
    test "returns current user's lists containing the account", %{conn: conn} do
      owner = user_fixture()
      member = user_fixture()

      {:ok, matching_list} =
        Social.create_list(%{user_id: owner.id, name: "Shipping", visibility: "private"})

      {:ok, _other_list} =
        Social.create_list(%{user_id: owner.id, name: "Reading", visibility: "private"})

      assert {:ok, _members} =
               Social.add_accounts_to_list(owner.id, matching_list.id, %{
                 "account_ids" => [to_string(member.id)]
               })

      conn =
        conn
        |> assign(:current_user, owner)
        |> AccountRelationshipController.lists(%{"id" => to_string(member.id)})

      assert [%{"id" => id, "title" => "Shipping", "accounts_count" => 1}] =
               json_response(conn, 200)

      assert id == to_string(matching_list.id)
    end

    test "does not expose another user's lists containing the account", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()
      member = user_fixture()

      {:ok, list} =
        Social.create_list(%{user_id: owner.id, name: "Private", visibility: "private"})

      assert {:ok, _members} =
               Social.add_accounts_to_list(owner.id, list.id, %{
                 "account_ids" => [to_string(member.id)]
               })

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.lists(%{"id" => to_string(member.id)})

      assert [] = json_response(conn, 200)
    end
  end

  describe "familiar_followers/2" do
    test "returns accounts the viewer follows that also follow the target", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      familiar = user_fixture(%{username: "familiar"})
      not_followed_by_viewer = user_fixture()
      not_following_target = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, familiar.id)
      assert {:ok, _follow} = Profiles.follow_user(familiar.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(not_followed_by_viewer.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(viewer.id, not_following_target.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.familiar_followers(%{
          "id[]" => [to_string(target.id)]
        })

      assert [%{"id" => id, "accounts" => accounts}] = json_response(conn, 200)
      assert id == to_string(target.id)

      assert [%{"id" => account_id, "username" => "familiar"}] = accounts
      assert account_id == to_string(familiar.id)
    end

    test "supports comma-separated ids and skips missing local accounts", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      familiar = user_fixture(%{username: "shared"})

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, familiar.id)
      assert {:ok, _follow} = Profiles.follow_user(familiar.id, target.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.familiar_followers(%{
          "id" => "#{target.id},-1,bad,#{target.id}"
        })

      assert [%{"id" => id, "accounts" => [%{"username" => "shared"}]}] =
               json_response(conn, 200)

      assert id == to_string(target.id)
    end

    test "respects hidden follower lists", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{hide_followers: true})
      familiar = user_fixture(%{username: "hiddenfamiliar"})

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, familiar.id)
      assert {:ok, _follow} = Profiles.follow_user(target.id, familiar.id)
      assert {:ok, _follow} = Profiles.follow_user(familiar.id, target.id)

      hidden_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.familiar_followers(%{
          "id[]" => [to_string(target.id)]
        })

      assert [%{"id" => id, "accounts" => []}] = json_response(hidden_conn, 200)
      assert id == to_string(target.id)

      owner_conn =
        build_conn()
        |> assign(:current_user, target)
        |> AccountRelationshipController.familiar_followers(%{
          "id[]" => [to_string(target.id)]
        })

      assert [%{"accounts" => accounts}] = json_response(owner_conn, 200)
      assert Enum.any?(accounts, &(&1["username"] == "hiddenfamiliar"))
    end
  end

  describe "follow/2 and unfollow/2" do
    test "follows and unfollows a local account", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.follow(%{"id" => to_string(target.id)})

      assert %{"id" => id, "following" => true, "followed_by" => false} =
               json_response(conn, 200)

      assert id == to_string(target.id)
      assert Profiles.following?(viewer.id, target.id)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.unfollow(%{"id" => to_string(target.id)})

      assert %{"id" => id, "following" => false, "followed_by" => false} =
               json_response(conn, 200)

      assert id == to_string(target.id)
      refute Profiles.following?(viewer.id, target.id)
    end

    test "rejects following yourself", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountRelationshipController.follow(%{"id" => to_string(user.id)})

      assert %{"error" => "cannot follow yourself"} = json_response(conn, 400)
    end
  end

  describe "follow_by_uri/2" do
    test "follows a local account by handle", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{username: "followbyhandle"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.follow_by_uri(%{
          "uri" => target.handle || target.username
        })

      assert %{"id" => id, "following" => true} = json_response(conn, 200)
      assert id == to_string(target.id)
      assert Profiles.following?(viewer.id, target.id)
    end

    test "returns not found for unknown identifiers", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.follow_by_uri(%{"uri" => "missing@example.invalid"})

      assert %{"error" => "account not found"} = json_response(conn, 404)
    end
  end

  describe "endorsements/2, endorse/2, and unendorse/2" do
    test "endorses, lists, reports, and unendorses a local account", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{username: "endorsedlocal"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.endorse(%{"id" => to_string(target.id)})

      assert %{"id" => id, "endorsed" => true} = json_response(conn, 200)
      assert id == to_string(target.id)
      assert Accounts.account_endorsed?(viewer.id, target)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.relationships(%{"id" => to_string(target.id)})

      assert [%{"id" => ^id, "endorsed" => true}] = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.endorsements(%{})

      assert [%{"id" => ^id, "username" => "endorsedlocal"}] = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.unendorse(%{"id" => to_string(target.id)})

      assert %{"id" => ^id, "endorsed" => false} = json_response(conn, 200)
      refute Accounts.account_endorsed?(viewer.id, target)
    end

    test "rejects endorsing yourself", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountRelationshipController.endorse(%{"id" => to_string(user.id)})

      assert %{"error" => "cannot endorse yourself"} = json_response(conn, 400)
    end

    test "endorses remote accounts", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture("endorsed.example")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.endorse(%{"id" => "remote:#{actor.id}"})

      assert %{"id" => id, "endorsed" => true} = json_response(conn, 200)
      assert id == to_string(actor.id)
      assert Accounts.account_endorsed?(viewer.id, actor)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.endorsements(%{})

      assert [%{"id" => account_id, "acct" => acct}] = json_response(conn, 200)
      assert account_id == "remote:#{actor.id}"
      assert acct =~ "@endorsed.example"
    end

    test "lists accounts endorsed by another local account", %{conn: conn} do
      viewer = user_fixture()
      source = user_fixture()
      local_target = user_fixture(%{username: "sourcepick"})
      remote_target = remote_actor_fixture("source.example")

      assert {:ok, _endorsement} = Accounts.endorse_account(source.id, local_target)
      assert {:ok, _endorsement} = Accounts.endorse_account(source.id, remote_target)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.account_endorsements(%{"id" => to_string(source.id)})

      accounts = json_response(conn, 200)
      assert Enum.any?(accounts, &(&1["username"] == "sourcepick"))
      assert Enum.any?(accounts, &(&1["acct"] =~ "@source.example"))
    end

    test "returns an empty endorsements list for remote accounts", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture("remote-source.example")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.account_endorsements(%{"id" => "remote:#{actor.id}"})

      assert [] = json_response(conn, 200)
    end
  end

  describe "subscribe/2 and unsubscribe/2" do
    test "subscribes and unsubscribes from a local account", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.subscribe(%{"id" => to_string(target.id)})

      assert %{"id" => id, "notifying" => true} = json_response(conn, 200)
      assert id == to_string(target.id)
      assert Accounts.account_subscribed?(viewer.id, target)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.relationships(%{"id" => to_string(target.id)})

      assert [%{"id" => ^id, "notifying" => true}] = json_response(conn, 200)

      conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.unsubscribe(%{"id" => to_string(target.id)})

      assert %{"id" => ^id, "notifying" => false} = json_response(conn, 200)
      refute Accounts.account_subscribed?(viewer.id, target)
    end

    test "rejects subscribing to yourself", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountRelationshipController.subscribe(%{"id" => to_string(user.id)})

      assert %{"error" => "cannot subscribe to yourself"} = json_response(conn, 400)
    end

    test "subscribes to remote accounts", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture("notify.example")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountRelationshipController.subscribe(%{"id" => "remote:#{actor.id}"})

      assert %{"id" => id, "notifying" => true} = json_response(conn, 200)
      assert id == to_string(actor.id)
      assert Accounts.account_subscribed?(viewer.id, actor)
    end
  end

  describe "remove_from_followers/2" do
    test "removes the target account from the current user's followers", %{conn: conn} do
      user = user_fixture()
      follower = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(follower.id, user.id)
      assert {:ok, _follow} = Profiles.follow_user(user.id, follower.id)
      assert Profiles.following?(follower.id, user.id)

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountRelationshipController.remove_from_followers(%{"id" => to_string(follower.id)})

      relationship = json_response(conn, 200)
      assert relationship["id"] == to_string(follower.id)
      assert relationship["following"] == true
      assert relationship["followed_by"] == false
      refute Profiles.following?(follower.id, user.id)
      assert Profiles.following?(user.id, follower.id)
    end

    test "rejects removing yourself from followers", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountRelationshipController.remove_from_followers(%{"id" => to_string(user.id)})

      assert %{"error" => "cannot remove yourself from followers"} = json_response(conn, 400)
    end
  end

  defp remote_actor_fixture(domain) do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/user#{unique}",
      username: "user#{unique}",
      domain: domain,
      inbox_url: "https://#{domain}/users/user#{unique}/inbox",
      public_key: "test-public-key-#{unique}"
    })
    |> Repo.insert!()
  end
end
