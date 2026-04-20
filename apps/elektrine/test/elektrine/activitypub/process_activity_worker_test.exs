defmodule Elektrine.ActivityPub.ProcessActivityWorkerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.DomainThrottler
  alias Elektrine.ActivityPub.ProcessActivityWorker
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures

  setup do
    if Process.whereis(DomainThrottler) == nil do
      start_supervised!({DomainThrottler, []})
    end

    :ok
  end

  test "retries URI-form Create activities when fetching the referenced object fails" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://create-fetch-#{unique_id}.invalid/users/author"

    activity = %{
      "id" => "https://create-fetch-#{unique_id}.invalid/activities/create/1",
      "type" => "Create",
      "actor" => actor_uri,
      "object" => "http://127.0.0.1/objects/#{unique_id}"
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert {:error, :create_object_fetch_failed} = ProcessActivityWorker.perform(job)
  end

  test "retries Move activities when referenced actors cannot be fetched" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://move-fetch-#{unique_id}.invalid/users/old"

    activity = %{
      "id" => "https://move-fetch-#{unique_id}.invalid/activities/move/1",
      "type" => "Move",
      "actor" => actor_uri,
      "object" => actor_uri,
      "target" => "https://move-fetch-#{unique_id}.invalid/users/new"
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert {:error, :move_actor_fetch_failed} = ProcessActivityWorker.perform(job)
  end

  test "retries URI-form Update activities when fetching the referenced object fails" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://update-fetch-#{unique_id}.invalid/users/author"

    activity = %{
      "id" => "https://update-fetch-#{unique_id}.invalid/activities/update/1",
      "type" => "Update",
      "actor" => actor_uri,
      "object" => "http://127.0.0.1/updates/#{unique_id}"
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert {:error, :update_object_fetch_failed} = ProcessActivityWorker.perform(job)
  end

  test "retries actor Update activities when refreshing the actor fails" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://update-actor-#{unique_id}.invalid/users/author"

    activity = %{
      "id" => "https://update-actor-#{unique_id}.invalid/activities/update/1",
      "type" => "Update",
      "actor" => actor_uri,
      "object" => %{
        "id" => actor_uri,
        "type" => "Person"
      }
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert {:error, :update_actor_fetch_failed} = ProcessActivityWorker.perform(job)
  end

  test "retries Announce activities when fetching the announced object fails" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://announce-fetch-#{unique_id}.invalid/users/booster"

    activity = %{
      "id" => "https://announce-fetch-#{unique_id}.invalid/activities/announce/1",
      "type" => "Announce",
      "actor" => actor_uri,
      "object" => "http://127.0.0.1/announces/#{unique_id}"
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert {:error, :announce_object_fetch_failed} = ProcessActivityWorker.perform(job)
  end

  test "ignores Announce activities that point at inaccessible remote activity wrappers" do
    unique_id = System.unique_integer([:positive])
    actor_uri = "https://announce-wrapper-#{unique_id}.invalid/users/booster"

    activity = %{
      "id" => "https://announce-wrapper-#{unique_id}.invalid/activities/announce/1",
      "type" => "Announce",
      "actor" => actor_uri,
      "object" => "https://remote.example/activities/like/#{unique_id}"
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert :ok = ProcessActivityWorker.perform(job)
  end

  test "retries Like activities when the remote actor cannot be fetched" do
    user = user_fixture()

    post =
      SocialFixtures.post_fixture(%{user: user})
      |> then(fn message ->
        status_uri =
          "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}/statuses/#{message.id}"

        Ecto.Changeset.change(message, activitypub_id: status_uri, activitypub_url: status_uri)
      end)
      |> Repo.update!()

    actor_uri = "https://like-actor-fetch.invalid/users/reactor"

    activity = %{
      "id" => "https://like-actor-fetch.invalid/activities/like/1",
      "type" => "Like",
      "actor" => actor_uri,
      "object" => post.activitypub_id
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => actor_uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert {:error, :like_actor_fetch_failed} = ProcessActivityWorker.perform(job)
  end

  test "does not retry unauthorized Update activities" do
    author = remote_actor_fixture("owner")
    intruder = remote_actor_fixture("intruder")
    object_id = "https://remote.example/objects/#{System.unique_integer([:positive])}"

    assert {:ok, _message} =
             Messaging.create_federated_message(%{
               content: "Original content",
               visibility: "public",
               activitypub_id: object_id,
               activitypub_url: object_id,
               federated: true,
               remote_actor_id: author.id,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    activity = %{
      "id" => "https://remote.example/activities/update/#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => intruder.uri,
      "object" => %{
        "id" => object_id,
        "type" => "Note",
        "content" => "<p>Malicious update</p>",
        "attributedTo" => intruder.uri,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => []
      }
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => intruder.uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert :ok = ProcessActivityWorker.perform(job)
  end

  test "does not retry unauthorized Delete activities" do
    author = remote_actor_fixture("deleteowner")
    intruder = remote_actor_fixture("deleteintruder")
    object_id = "https://remote.example/objects/#{System.unique_integer([:positive])}"

    assert {:ok, _message} =
             Messaging.create_federated_message(%{
               content: "Original content",
               visibility: "public",
               activitypub_id: object_id,
               activitypub_url: object_id,
               federated: true,
               remote_actor_id: author.id,
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    activity = %{
      "id" => "https://remote.example/activities/delete/#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => intruder.uri,
      "object" => object_id
    }

    job = %Oban.Job{
      args: %{"activity" => activity, "actor_uri" => intruder.uri},
      inserted_at: DateTime.utc_now(),
      attempt: 1
    }

    assert :ok = ProcessActivityWorker.perform(job)
  end

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}#{unique_id}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/#{username}",
      username: username,
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
