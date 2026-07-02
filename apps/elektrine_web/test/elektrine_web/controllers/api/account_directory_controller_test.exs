defmodule ElektrineWeb.API.AccountDirectoryControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo

  describe "index/2" do
    test "lists discoverable public accounts ordered by activity", %{conn: conn} do
      older = user_fixture(%{username: "directoryolder"})
      newer = user_fixture(%{username: "directorynewer"})
      private = user_fixture(%{username: "directoryprivate", profile_visibility: "private"})
      suspended = user_fixture(%{username: "directorysuspended"})

      {:ok, older} = Accounts.update_user_display_name(older, "Older Account")
      {:ok, newer} = Accounts.update_user_display_name(newer, "Newer Account")

      old_seen = ~U[2030-01-01 00:00:00Z]
      new_seen = ~U[2030-01-02 00:00:00Z]

      Repo.update_all(from(user in User, where: user.id == ^older.id),
        set: [last_seen_at: old_seen]
      )

      Repo.update_all(from(user in User, where: user.id == ^newer.id),
        set: [last_seen_at: new_seen]
      )

      Repo.update_all(from(user in User, where: user.id == ^suspended.id),
        set: [suspended: true]
      )

      conn = get(conn, "/api/v1/directory?local=true&limit=10")

      accounts = json_response(conn, 200)
      account_ids = Enum.map(accounts, & &1["id"])
      newer_id = to_string(newer.id)
      older_id = to_string(older.id)

      assert [^newer_id, ^older_id | _] = account_ids
      refute to_string(private.id) in account_ids
      refute to_string(suspended.id) in account_ids

      assert %{"acct" => acct, "display_name" => "Newer Account", "remote" => false} =
               hd(accounts)

      assert acct == newer.handle
    end

    test "includes cached remote actors unless local=true is passed", %{conn: conn} do
      actor =
        remote_actor_fixture(%{
          username: "directoryremote",
          domain: "remote.example",
          display_name: "Remote Directory"
        })

      conn = get(conn, "/api/v1/directory?limit=10")

      assert Enum.any?(json_response(conn, 200), fn account ->
               account["id"] == "remote:#{actor.id}" and
                 account["acct"] == "directoryremote@remote.example" and
                 account["display_name"] == "Remote Directory" and
                 account["remote"] == true
             end)

      conn = get(build_conn(), "/api/v1/directory?local=true&limit=10")

      refute Enum.any?(json_response(conn, 200), fn account ->
               account["id"] == "remote:#{actor.id}"
             end)
    end

    test "caps limit and supports offset pagination", %{conn: conn} do
      users =
        for index <- 1..3 do
          user_fixture(%{username: "directorypage#{index}"})
        end

      users
      |> Enum.with_index(1)
      |> Enum.each(fn {user, index} ->
        seen_at = DateTime.add(~U[2030-01-01 00:00:00Z], index, :day)
        Repo.update_all(from(u in User, where: u.id == ^user.id), set: [last_seen_at: seen_at])
      end)

      conn = get(conn, "/api/v1/directory?local=true&limit=1&offset=1")

      assert [%{"id" => id}] = json_response(conn, 200)
      assert id == to_string(Enum.at(users, 1).id)
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
      last_fetched_at: Map.get(attrs, :last_fetched_at, ~U[2026-01-03 00:00:00Z]),
      manually_approves_followers: Map.get(attrs, :manually_approves_followers, false)
    }

    %Actor{}
    |> Actor.changeset(defaults)
    |> Repo.insert!()
  end
end
