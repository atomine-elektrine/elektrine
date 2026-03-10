defmodule Elektrine.ActivityPub.Handlers.FlagHandlerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Handlers.FlagHandler
  alias Elektrine.Messaging
  alias Elektrine.Repo

  describe "handle/3" do
    setup do
      # Create a local user who might be reported
      local_user = user_fixture(%{username: "localuser"})

      # Create an admin user for the report system (avoid reserved "admin" username)
      admin_user = user_fixture(%{username: "moderator"})
      {:ok, admin_user} = Accounts.update_user_admin_status(admin_user, true)

      %{local_user: local_user, admin: admin_user}
    end

    test "handles Flag activity targeting local user", %{local_user: local_user} do
      base_url = Elektrine.ActivityPub.instance_url()

      activity = %{
        "type" => "Flag",
        "actor" => "https://remote.server/users/reporter",
        "object" => ["#{base_url}/users/#{local_user.username}"],
        "content" => "This user is posting spam"
      }

      # This will fail to create the report because the remote actor doesn't exist,
      # but we can verify the handler doesn't crash
      result = FlagHandler.handle(activity, "https://remote.server/users/reporter", nil)

      # Should either succeed or handle gracefully
      assert result in [{:ok, :report_received}, {:ok, :ignored}, {:error, :no_system_reporter}]
    end

    test "handles Flag activity without content field", %{local_user: local_user} do
      base_url = Elektrine.ActivityPub.instance_url()

      activity = %{
        "type" => "Flag",
        "actor" => "https://remote.server/users/reporter",
        "object" => ["#{base_url}/users/#{local_user.username}"]
      }

      # Should handle nil content gracefully
      result = FlagHandler.handle(activity, "https://remote.server/users/reporter", nil)
      assert result in [{:ok, :report_received}, {:ok, :ignored}, {:error, :no_system_reporter}]
    end

    test "ignores Flag activity targeting non-local users" do
      activity = %{
        "type" => "Flag",
        "actor" => "https://remote.server/users/reporter",
        "object" => ["https://other.server/users/someone"],
        "content" => "Not our problem"
      }

      assert {:ok, :ignored} =
               FlagHandler.handle(activity, "https://remote.server/users/reporter", nil)
    end

    test "handles Flag activity with multiple objects" do
      base_url = Elektrine.ActivityPub.instance_url()

      activity = %{
        "type" => "Flag",
        "actor" => "https://remote.server/users/reporter",
        "object" => [
          "https://remote.server/users/baduser",
          "#{base_url}/posts/nonexistent"
        ],
        "content" => "Mixed report"
      }

      # Should handle gracefully even with non-existent content
      result = FlagHandler.handle(activity, "https://remote.server/users/reporter", nil)
      assert elem(result, 0) == :ok
    end

    test "matches reported content by activitypub URL variant" do
      reporter = remote_actor_fixture("reporter")
      author = remote_actor_fixture("author")
      canonical_id = "https://remote.server/objects/#{System.unique_integer([:positive])}"
      object_url = "#{canonical_id}/context"

      assert {:ok, _message} =
               Messaging.create_federated_message(%{
                 content: "Remote post",
                 visibility: "public",
                 activitypub_id: canonical_id,
                 activitypub_url: object_url,
                 federated: true,
                 remote_actor_id: author.id,
                 inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
               })

      activity = %{
        "type" => "Flag",
        "actor" => reporter.uri,
        "object" => [object_url],
        "content" => "Reported content"
      }

      assert {:ok, :report_received} = FlagHandler.handle(activity, reporter.uri, nil)
    end
  end

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}#{unique_id}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.server/users/#{username}",
      username: username,
      domain: "remote.server",
      inbox_url: "https://remote.server/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
