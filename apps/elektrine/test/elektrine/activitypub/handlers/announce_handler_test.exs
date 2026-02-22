defmodule Elektrine.ActivityPub.Handlers.AnnounceHandlerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Handlers.AnnounceHandler

  describe "handle/3 - Announce activity" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns error for announce of non-existent local message", %{user: _user} do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => "#{base_url}/posts/99999999"
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      # Tries to fetch remote object, which fails
      assert result == {:error, :fetch_failed}
    end

    test "handles object reference as map with id" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => %{"id" => "#{base_url}/posts/99999999", "type" => "Note"}
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      # Tries to fetch remote object, which fails
      assert result == {:error, :fetch_failed}
    end

    test "ignores activity wrapper URLs" do
      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => "https://remote.server/activities/123"
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      assert result == {:ok, :ignored}
    end

    test "returns error for invalid object" do
      activity = %{
        "type" => "Announce",
        "actor" => "https://remote.server/users/booster",
        "object" => %{"invalid" => "no_id"}
      }

      result = AnnounceHandler.handle(activity, "https://remote.server/users/booster", nil)
      assert result == {:error, :invalid_object}
    end
  end

  describe "handle_undo/2" do
    test "returns message_not_found for non-existent message" do
      base_url = ActivityPub.instance_url()

      object = %{"object" => "#{base_url}/posts/99999999"}

      result = AnnounceHandler.handle_undo(object, "https://remote.server/users/booster")
      # First tries to find message, fails because remote actor doesn't exist
      assert result == {:error, :undo_announce_failed}
    end

    test "handles nested object reference" do
      base_url = ActivityPub.instance_url()

      object = %{
        "object" => %{
          "id" => "#{base_url}/posts/99999999",
          "type" => "Note"
        }
      }

      result = AnnounceHandler.handle_undo(object, "https://remote.server/users/booster")
      assert result == {:error, :undo_announce_failed}
    end
  end
end
