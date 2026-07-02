defmodule Elektrine.Developer.Exports.AccountExporterTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.UserBlock
  alias Elektrine.Accounts.UserMute
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.UserBlock, as: ActivityPubUserBlock
  alias Elektrine.Developer.Exports.AccountExporter
  alias Elektrine.Domains
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  test "account export includes OwnRoot recovery metadata" do
    user = user_fixture(%{username: "exportdomain", handle: "exportdomain"})
    built_in_domain = "exportdomain.#{Domains.default_profile_domain()}"

    assert {:ok, _identity} =
             Profiles.create_per_site_identity(user, %{
               "site_key" => "hn",
               "base_domain" => built_in_domain
             })

    file_path =
      Path.join(System.tmp_dir!(), "account-export-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(file_path) end)

    assert {:ok, _count} = AccountExporter.export(user.id, file_path, "json")

    data =
      file_path
      |> File.read!()
      |> Jason.decode!()

    assert %{
             "provider" => provider,
             "portable_root" => "dns",
             "domains" => domains
           } = data["own_root"]

    assert provider == Domains.public_base_url()

    exported_domain = Enum.find(domains, &(&1["domain"] == built_in_domain))

    assert exported_domain["subject"] == "domain:#{built_in_domain}"
    assert exported_domain["did"] == "did:web:#{built_in_domain}"
    assert exported_domain["own_root"]["subject"] == "domain:#{built_in_domain}"
    assert exported_domain["did_document"]["id"] == "did:web:#{built_in_domain}"
    assert exported_domain["migration"]["own_root"] =~ "/.well-known/own-root"
    assert [identity] = exported_domain["own_root"]["per_site_identities"]["identities"]
    assert identity["site_key"] == "hn"
    assert identity["domain"] == "hn.#{built_in_domain}"
    assert identity["subject"] == "domain:hn.#{built_in_domain}"
  end

  test "account export includes portable relationship lists" do
    user = user_fixture(%{username: "portablerel", handle: "portablerel"})
    local_follow = user_fixture(%{username: "localfollow", handle: "localfollow"})
    local_block = user_fixture(%{username: "localblock", handle: "localblock"})
    local_mute = user_fixture(%{username: "localmute", handle: "localmute"})

    remote_follow = remote_actor_fixture("remote-follow", "remote-follow.example")
    remote_block = remote_actor_fixture("remote-block", "remote-block.example")
    remote_mute = remote_actor_fixture("remote-mute", "remote-mute.example")

    insert_local_follow(user.id, local_follow.id)
    insert_local_block(user.id, local_block.id)
    insert_local_mute(user.id, local_mute.id)
    insert_remote_follow(user.id, remote_follow.id)
    insert_remote_relationship(user.id, remote_block.uri, "user")
    insert_remote_relationship(user.id, remote_mute.uri, "mute")
    insert_remote_relationship(user.id, "blocked-domain.example", "domain")

    file_path =
      Path.join(
        System.tmp_dir!(),
        "account-relationships-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(file_path) end)

    assert {:ok, count} = AccountExporter.export(user.id, file_path, "json")
    assert count == 8

    data =
      file_path
      |> File.read!()
      |> Jason.decode!()

    assert %{
             "following" => following,
             "blocks" => blocks,
             "mutes" => mutes,
             "domain_blocks" => domain_blocks,
             "import_lists" => import_lists
           } = data["relationships"]

    assert Enum.any?(
             following,
             &(&1["account"] == "localfollow@#{ActivityPub.instance_domain()}")
           )

    assert Enum.any?(following, &(&1["account"] == "remote-follow@remote-follow.example"))
    assert Enum.any?(blocks, &(&1["account"] == "localblock@#{ActivityPub.instance_domain()}"))
    assert Enum.any?(blocks, &(&1["account"] == "remote-block@remote-block.example"))
    assert Enum.any?(mutes, &(&1["account"] == "localmute@#{ActivityPub.instance_domain()}"))
    assert Enum.any?(mutes, &(&1["account"] == "remote-mute@remote-mute.example"))
    assert [%{"domain" => "blocked-domain.example"}] = domain_blocks

    assert "remote-follow@remote-follow.example" in import_lists["follows"]
    assert "remote-block@remote-block.example" in import_lists["blocks"]
    assert "remote-mute@remote-mute.example" in import_lists["mutes"]
    assert "blocked-domain.example" in import_lists["domain_blocks"]
  end

  defp insert_local_follow(follower_id, followed_id) do
    %Follow{}
    |> Follow.changeset(%{follower_id: follower_id, followed_id: followed_id})
    |> Repo.insert!()
  end

  defp insert_local_block(blocker_id, blocked_id) do
    %UserBlock{}
    |> UserBlock.changeset(%{blocker_id: blocker_id, blocked_id: blocked_id})
    |> Repo.insert!()
  end

  defp insert_local_mute(muter_id, muted_id) do
    %UserMute{}
    |> UserMute.changeset(%{muter_id: muter_id, muted_id: muted_id})
    |> Repo.insert!()
  end

  defp insert_remote_follow(follower_id, remote_actor_id) do
    %Follow{}
    |> Follow.changeset(%{
      follower_id: follower_id,
      remote_actor_id: remote_actor_id,
      pending: false
    })
    |> Repo.insert!()
  end

  defp insert_remote_relationship(user_id, blocked_uri, block_type) do
    %ActivityPubUserBlock{}
    |> ActivityPubUserBlock.changeset(%{
      user_id: user_id,
      blocked_uri: blocked_uri,
      block_type: block_type
    })
    |> Repo.insert!()
  end

  defp remote_actor_fixture(username, domain) do
    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: username,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      actor_type: "Person",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{}
    })
    |> Repo.insert!()
  end
end
