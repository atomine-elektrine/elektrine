defmodule Elektrine.Accounts.AccountImportWorkerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.Accounts.AccountImportWorker
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Repo

  test "imports remote mutes from cached account handles" do
    user = user_fixture()
    actor = remote_actor_fixture("alice", "remote-mute.example")

    assert :ok =
             AccountImportWorker.perform(%Oban.Job{
               args: %{
                 "user_id" => user.id,
                 "type" => "mute",
                 "identifier" => "alice@remote-mute.example"
               }
             })

    assert Accounts.remote_actor_muted?(user.id, actor.id)
  end

  test "imports remote mutes from cached actor URLs" do
    user = user_fixture()
    actor = remote_actor_fixture("urlmute", "remote-url-mute.example")

    assert :ok =
             AccountImportWorker.perform(%Oban.Job{
               args: %{
                 "user_id" => user.id,
                 "type" => "mute",
                 "identifier" => actor.uri
               }
             })

    assert Accounts.remote_actor_muted?(user.id, actor.id)
  end

  test "imports remote blocks from cached actor URLs" do
    user = user_fixture()
    actor = remote_actor_fixture("urlblock", "remote-url-block.example")

    assert :ok =
             AccountImportWorker.perform(%Oban.Job{
               args: %{
                 "user_id" => user.id,
                 "type" => "block",
                 "identifier" => actor.uri
               }
             })

    assert Accounts.remote_actor_blocked?(user.id, actor.id)
  end

  test "rejects imports above the durable queue cap" do
    user = user_fixture()

    identifiers =
      for index <- 1..(AccountImportWorker.max_identifiers() + 1) do
        "person#{index}@example.com"
      end

    assert {:error, :too_many_import_identifiers} =
             AccountImportWorker.enqueue_many(user.id, "follow", identifiers)
  end

  test "imports domain blocks without resolving them as accounts" do
    user = user_fixture()

    assert :ok =
             AccountImportWorker.perform(%Oban.Job{
               args: %{
                 "user_id" => user.id,
                 "type" => "domain_block",
                 "identifier" => "https://Bad-Domain.example/users/alice"
               }
             })

    assert Accounts.list_blocked_domains(user.id) == ["bad-domain.example"]
  end

  test "strips UTF-8 BOMs from imported identifiers" do
    user = user_fixture()

    assert :ok =
             AccountImportWorker.perform(%Oban.Job{
               args: %{
                 "user_id" => user.id,
                 "type" => "domain_block",
                 "identifier" => <<0xEF, 0xBB, 0xBF>> <> "bom-domain.example"
               }
             })

    assert Accounts.list_blocked_domains(user.id) == ["bom-domain.example"]
  end

  defp remote_actor_fixture(username, domain) do
    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      actor_type: "Person",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{}
    })
    |> Repo.insert!()
  end
end
