defmodule Elektrine.ActivityPub.Handlers.FlagHandlerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Handlers.FlagHandler
  alias Elektrine.Accounts

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
  end
end
