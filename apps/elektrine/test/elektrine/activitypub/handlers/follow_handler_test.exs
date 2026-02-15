defmodule Elektrine.ActivityPub.Handlers.FollowHandlerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Handlers.FollowHandler
  alias Elektrine.ActivityPub

  describe "handle/3 - Follow activity" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns error for follow of non-existent local user" do
      base_url = ActivityPub.instance_url()

      activity = %{
        "type" => "Follow",
        "id" => "https://remote.server/activities/follow/123",
        "actor" => "https://remote.server/users/follower",
        "object" => "#{base_url}/users/nonexistentuser"
      }

      result =
        FollowHandler.handle(activity, "https://remote.server/users/follower", nil)

      assert result == {:error, :handle_follow_failed}
    end

    test "returns error for follow with non-local target" do
      activity = %{
        "type" => "Follow",
        "id" => "https://remote.server/activities/follow/123",
        "actor" => "https://remote.server/users/follower",
        "object" => "https://other.server/users/someone"
      }

      result =
        FollowHandler.handle(activity, "https://remote.server/users/follower", nil)

      assert result == {:error, :handle_follow_failed}
    end
  end

  describe "handle_accept/3" do
    test "returns :unhandled for non-Follow Accept" do
      activity = %{
        "type" => "Accept",
        "actor" => "https://remote.server/users/someone",
        "object" => %{"type" => "Something", "id" => "https://example.com/something/123"}
      }

      result = FollowHandler.handle_accept(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unhandled}
    end

    test "returns :unknown_follow for Accept of unknown Follow" do
      activity = %{
        "type" => "Accept",
        "actor" => "https://remote.server/users/someone",
        "object" => %{
          "type" => "Follow",
          "id" => "https://our.server/activities/follow/nonexistent"
        }
      }

      result = FollowHandler.handle_accept(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unknown_follow}
    end
  end

  describe "handle_reject/3" do
    test "returns :unhandled for non-Follow Reject" do
      activity = %{
        "type" => "Reject",
        "actor" => "https://remote.server/users/someone",
        "object" => %{"type" => "Something", "id" => "https://example.com/something/123"}
      }

      result = FollowHandler.handle_reject(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unhandled}
    end

    test "returns :unknown_follow for Reject of unknown Follow" do
      activity = %{
        "type" => "Reject",
        "actor" => "https://remote.server/users/someone",
        "object" => %{
          "type" => "Follow",
          "id" => "https://our.server/activities/follow/nonexistent"
        }
      }

      result = FollowHandler.handle_reject(activity, "https://remote.server/users/someone", nil)
      assert result == {:ok, :unknown_follow}
    end
  end

  describe "handle_undo/2" do
    test "returns error when remote actor cannot be fetched" do
      base_url = ActivityPub.instance_url()

      result =
        FollowHandler.handle_undo(
          %{"object" => "#{base_url}/users/someone"},
          "https://nonexistent.server/users/unfollower"
        )

      assert result == {:error, :undo_follow_failed}
    end

    test "returns :invalid for invalid undo object" do
      result = FollowHandler.handle_undo(nil, "https://remote.server/users/unfollower")
      assert result == {:ok, :invalid}
    end

    test "handles object as nested map" do
      base_url = ActivityPub.instance_url()

      result =
        FollowHandler.handle_undo(
          %{"object" => %{"id" => "#{base_url}/users/someone"}},
          "https://remote.server/users/unfollower"
        )

      assert result == {:error, :undo_follow_failed}
    end
  end
end
