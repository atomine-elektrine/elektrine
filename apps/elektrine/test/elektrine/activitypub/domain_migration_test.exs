defmodule Elektrine.ActivityPub.DomainMigrationTest do
  use Elektrine.DataCase, async: true
  use Oban.Testing, repo: Elektrine.Repo

  import Ecto.Query
  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Activity, Actor, Delivery, DomainMigration}
  alias Elektrine.Profiles
  alias Elektrine.Repo

  describe "move_account/3" do
    test "stores the verified target actor and queues move deliveries" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        user = user_fixture()
        old_actor_uri = ActivityPub.actor_uri(user)

        target_actor =
          remote_actor_fixture("target", %{
            "alsoKnownAs" => [old_actor_uri]
          })

        follower = remote_actor_fixture("follower")
        assert {:ok, _follow} = Profiles.create_remote_follow(follower.id, user.id)

        assert {:ok, summary} = DomainMigration.move_account(user, target_actor.uri)

        assert summary.target_actor_uri == target_actor.uri
        assert summary.old_actor_uri == old_actor_uri
        assert summary.deliveries_queued == 1
        assert Accounts.get_user!(user.id).moved_to == target_actor.uri

        activity =
          Activity
          |> where([a], a.activity_type == "Move" and a.internal_user_id == ^user.id)
          |> Repo.one!()

        assert activity.data["actor"] == old_actor_uri
        assert activity.data["object"] == old_actor_uri
        assert activity.data["target"] == target_actor.uri

        delivery =
          Delivery
          |> where([d], d.activity_id == ^activity.id)
          |> Repo.one!()

        assert delivery.inbox_url == follower.inbox_url
        assert delivery.status == "pending"
      end)
    end

    test "resolves cached acct targets to canonical actor URIs" do
      user = user_fixture()
      old_actor_uri = ActivityPub.actor_uri(user)

      target_actor =
        remote_actor_fixture("target-acct", %{
          "alsoKnownAs" => [%{"href" => old_actor_uri <> "?utm=ignored"}]
        })

      assert {:ok, summary} =
               DomainMigration.move_account(
                 user,
                 "acct:#{target_actor.username}@#{target_actor.domain}"
               )

      assert summary.target_actor_uri == target_actor.uri
      assert Accounts.get_user!(user.id).moved_to == target_actor.uri
    end

    test "rejects unverified target actors" do
      user = user_fixture()
      target_actor = remote_actor_fixture("unverified", %{"alsoKnownAs" => []})

      assert {:error, :move_target_not_verified} =
               DomainMigration.move_account(user, target_actor.uri)

      assert is_nil(Accounts.get_user!(user.id).moved_to)
      refute Repo.exists?(from(a in Activity, where: a.activity_type == "Move"))
    end
  end

  defp remote_actor_fixture(suffix, metadata \\ %{}) do
    unique = System.unique_integer([:positive])
    domain = "move-#{unique}.example"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{suffix}",
      username: suffix,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{suffix}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: metadata
    })
    |> Repo.insert!()
  end
end
