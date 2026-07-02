defmodule ElektrineWeb.API.AccountSearchControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountSearchController

  describe "search/2" do
    test "finds local accounts by handle", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{username: "localalpha"})
      {:ok, target} = Accounts.update_user_display_name(target, "Local Alpha")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.search(%{"q" => "alpha"})

      assert [%{"id" => id, "acct" => acct, "display_name" => "Local Alpha", "remote" => false}] =
               json_response(conn, 200)

      assert id == to_string(target.id)
      assert acct == target.handle
    end

    test "finds cached remote accounts by full handle", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture(%{username: "remotealpha", domain: "remote.example"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.search(%{"q" => "remotealpha@remote.example"})

      assert [%{"id" => id, "acct" => "remotealpha@remote.example", "remote" => true}] =
               json_response(conn, 200)

      assert id == "remote:#{actor.id}"
    end

    test "returns an empty list for blank search", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.search(%{"q" => ""})

      assert [] = json_response(conn, 200)
    end

    test "does not discover private local accounts", %{conn: conn} do
      viewer = user_fixture()
      _private = user_fixture(%{username: "privatesearch", profile_visibility: "private"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.search(%{"q" => "privatesearch"})

      assert [] = json_response(conn, 200)
    end

    test "filters account results by viewer relationship policy", %{conn: conn} do
      viewer = user_fixture()
      muted = user_fixture(%{username: "mutedsearch"})
      blocked = user_fixture(%{username: "blockedsearch"})
      blocker = user_fixture(%{username: "blockersearch"})

      muted_actor =
        remote_actor_fixture(%{username: "mutedremote", domain: "remote.example"})

      domain_actor =
        remote_actor_fixture(%{username: "domainremote", domain: "blocked.example"})

      assert {:ok, _mute} = Accounts.mute_user(viewer.id, muted.id)
      assert {:ok, _block} = Accounts.block_user(viewer.id, blocked.id)
      assert {:ok, _block} = Accounts.block_user(blocker.id, viewer.id)
      assert {:ok, _mute} = Accounts.mute_remote_actor(viewer.id, muted_actor.id)
      assert {:ok, _block} = Accounts.block_domain(viewer.id, "blocked.example")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.search(%{"q" => "search", "limit" => "20"})

      account_ids = Enum.map(json_response(conn, 200), & &1["id"])

      refute to_string(muted.id) in account_ids
      refute to_string(blocked.id) in account_ids
      refute to_string(blocker.id) in account_ids
      refute "remote:#{muted_actor.id}" in account_ids
      refute "remote:#{domain_actor.id}" in account_ids
    end

    test "embeds relationships in account search results when requested", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{username: "embeddedalpha"})

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, target.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.search(%{
          "q" => "embeddedalpha",
          "with_relationships" => "true"
        })

      assert [
               %{
                 "id" => id,
                 "pleroma" => %{"relationship" => %{"following" => true}}
               }
             ] = json_response(conn, 200)

      assert id == to_string(target.id)
    end
  end

  describe "lookup/2" do
    test "looks up a local account by bare handle", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{username: "lookuplocal"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.lookup(%{"acct" => target.handle})

      assert %{"id" => id, "acct" => acct, "remote" => false} = json_response(conn, 200)
      assert id == to_string(target.id)
      assert acct == target.handle
    end

    test "looks up a remote account by full handle", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture(%{username: "lookupremote", domain: "remote.example"})

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.lookup(%{"acct" => "@lookupremote@remote.example"})

      assert %{"id" => id, "acct" => "lookupremote@remote.example", "remote" => true} =
               json_response(conn, 200)

      assert id == "remote:#{actor.id}"
    end

    test "embeds relationships in account lookup when requested", %{conn: conn} do
      viewer = user_fixture()
      actor = remote_actor_fixture(%{username: "lookupmuted", domain: "remote.example"})

      assert {:ok, _mute} = Accounts.mute_remote_actor(viewer.id, actor.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.lookup(%{
          "acct" => "@lookupmuted@remote.example",
          "with_relationships" => "true"
        })

      assert %{
               "id" => id,
               "pleroma" => %{"relationship" => %{"muting" => true}}
             } = json_response(conn, 200)

      assert id == "remote:#{actor.id}"
    end

    test "returns 404 for unknown accounts", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.lookup(%{"acct" => "missing@example.invalid"})

      assert %{"error" => "account not found"} = json_response(conn, 404)
    end
  end

  describe "show/2" do
    test "shows local accounts by id", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => to_string(target.id)})

      assert %{"id" => id, "acct" => acct, "remote" => false} = json_response(conn, 200)
      assert id == to_string(target.id)
      assert acct == target.handle
    end

    test "embeds relationships in account show when requested", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(viewer.id, target.id)
      assert {:ok, _note} = Accounts.put_account_note(viewer.id, {:user, target.id}, "watch")

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{
          "id" => to_string(target.id),
          "with_relationships" => "true"
        })

      assert %{
               "pleroma" => %{
                 "relationship" => %{"following" => true, "note" => "watch"}
               }
             } = json_response(conn, 200)
    end

    test "shows local account counters", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture()
      follower = user_fixture()
      followed = user_fixture()
      post = post_fixture(%{user: target, visibility: "public", content: "counted"})
      draft = post_fixture(%{user: target, visibility: "public", content: "not counted"})
      {:ok, _draft} = draft |> Ecto.Changeset.change(is_draft: true) |> Repo.update()

      assert {:ok, _follow} = Profiles.follow_user(follower.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(target.id, followed.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => to_string(target.id)})

      assert %{
               "followers_count" => 1,
               "following_count" => 1,
               "statuses_count" => 1,
               "last_status_at" => last_status_at,
               "fields" => [],
               "emojis" => []
             } = json_response(conn, 200)

      assert last_status_at == date_iso(post.inserted_at)
    end

    test "hides local account follow counters from other users", %{conn: conn} do
      viewer = user_fixture()
      target = user_fixture(%{hide_followers: true, hide_follows: true})
      follower = user_fixture()
      followed = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(follower.id, target.id)
      assert {:ok, _follow} = Profiles.follow_user(target.id, followed.id)

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => to_string(target.id)})

      assert %{"followers_count" => 0, "following_count" => 0} = json_response(conn, 200)
    end

    test "shows hidden local account follow counters to the owner", %{conn: conn} do
      owner = user_fixture(%{hide_followers: true, hide_follows: true})
      follower = user_fixture()
      followed = user_fixture()

      assert {:ok, _follow} = Profiles.follow_user(follower.id, owner.id)
      assert {:ok, _follow} = Profiles.follow_user(owner.id, followed.id)

      conn =
        conn
        |> assign(:current_user, owner)
        |> AccountSearchController.show(%{"id" => to_string(owner.id)})

      assert %{"followers_count" => 1, "following_count" => 1} = json_response(conn, 200)
    end

    test "shows opted-in birthday metadata and hides private birthday metadata", %{conn: conn} do
      viewer = user_fixture()

      visible =
        user_fixture(%{
          username: "visiblebirthday",
          birthday: ~D[2001-02-12],
          show_birthday: true
        })

      hidden =
        user_fixture(%{
          username: "hiddenbirthday",
          birthday: ~D[2001-02-12],
          show_birthday: false
        })

      visible_conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => to_string(visible.id)})

      assert %{"pleroma" => %{"birthday" => "2001-02-12"}} = json_response(visible_conn, 200)

      hidden_conn =
        build_conn()
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => to_string(hidden.id)})

      assert %{"pleroma" => %{"birthday" => nil}} = json_response(hidden_conn, 200)
    end

    test "shows hidden birthday metadata to the account owner", %{conn: conn} do
      owner = user_fixture(%{birthday: ~D[2001-02-12], show_birthday: false})

      conn =
        conn
        |> assign(:current_user, owner)
        |> AccountSearchController.show(%{"id" => to_string(owner.id)})

      assert %{"pleroma" => %{"birthday" => "2001-02-12"}} = json_response(conn, 200)
    end

    test "shows account migration metadata for local accounts", %{conn: conn} do
      viewer = user_fixture()

      target =
        user_fixture(%{
          also_known_as: ["https://old.example/users/account"],
          moved_to: "https://new.example/users/account"
        })

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => to_string(target.id)})

      assert %{
               "pleroma" => %{
                 "also_known_as" => ["https://old.example/users/account"],
                 "moved_to" => "https://new.example/users/account"
               }
             } = json_response(conn, 200)
    end

    test "shows remote accounts by prefixed id", %{conn: conn} do
      viewer = user_fixture()

      actor =
        remote_actor_fixture(%{
          username: "showremote",
          domain: "remote.example",
          metadata: %{
            "followers_count" => 12,
            "following_count" => 7,
            "statuses_count" => 34,
            "last_status_at" => "2026-06-30",
            "fields" => [%{"name" => "site", "value" => "https://remote.example"}],
            "emojis" => [%{"shortcode" => "wave"}]
          }
        })

      conn =
        conn
        |> assign(:current_user, viewer)
        |> AccountSearchController.show(%{"id" => "remote:#{actor.id}"})

      assert %{
               "id" => id,
               "acct" => "showremote@remote.example",
               "remote" => true,
               "followers_count" => 12,
               "following_count" => 7,
               "statuses_count" => 34,
               "last_status_at" => "2026-06-30",
               "fields" => [%{"name" => "site", "value" => "https://remote.example"}],
               "emojis" => [%{"shortcode" => "wave"}]
             } =
               json_response(conn, 200)

      assert id == "remote:#{actor.id}"
    end
  end

  defp remote_actor_fixture(attrs) do
    unique = System.unique_integer([:positive])
    username = Map.get(attrs, :username, "remote#{unique}")
    domain = Map.get(attrs, :domain, "remote#{unique}.example")

    defaults = %{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: Map.get(attrs, :display_name, username),
      summary: Map.get(attrs, :summary, ""),
      avatar_url: Map.get(attrs, :avatar_url),
      inbox_url: "https://#{domain}/inbox",
      outbox_url: "https://#{domain}/users/#{username}/outbox",
      public_key: "test-public-key-#{unique}",
      actor_type: Map.get(attrs, :actor_type, "Person"),
      manually_approves_followers: Map.get(attrs, :manually_approves_followers, false),
      metadata: Map.get(attrs, :metadata, %{})
    }

    %Actor{}
    |> Actor.changeset(defaults)
    |> Repo.insert!()
  end

  defp date_iso(%Date{} = date), do: Date.to_iso8601(date)
  defp date_iso(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp date_iso(%NaiveDateTime{} = datetime),
    do: datetime |> NaiveDateTime.to_date() |> Date.to_iso8601()
end
