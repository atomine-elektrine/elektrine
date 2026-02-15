defmodule Elektrine.FriendsTest do
  use Elektrine.DataCase

  alias Elektrine.Friends
  import Elektrine.AccountsFixtures

  describe "friend requests" do
    setup do
      # Create test users
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()

      %{user1: user1, user2: user2, user3: user3}
    end

    test "can send friend request", %{user1: user1, user2: user2} do
      assert {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      assert request.requester_id == user1.id
      assert request.recipient_id == user2.id
      assert request.status == "pending"
    end

    test "cannot send duplicate friend request", %{user1: user1, user2: user2} do
      {:ok, _request} = Friends.send_friend_request(user1.id, user2.id)
      assert {:error, :request_already_exists} = Friends.send_friend_request(user1.id, user2.id)
    end

    test "cannot friend yourself", %{user1: user1} do
      assert {:error, :cannot_friend_self} = Friends.send_friend_request(user1.id, user1.id)
    end

    test "can accept friend request", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      assert {:ok, accepted} = Friends.accept_friend_request(request.id, user2.id)
      assert accepted.status == "accepted"
      assert Friends.friends?(user1.id, user2.id)
      assert Friends.friends?(user2.id, user1.id)
    end

    test "can reject friend request", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      assert {:ok, rejected} = Friends.reject_friend_request(request.id, user2.id)
      assert rejected.status == "rejected"
      refute Friends.friends?(user1.id, user2.id)
    end

    test "can cancel sent friend request", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      assert {:ok, _} = Friends.cancel_friend_request(request.id, user1.id)
      refute Friends.friends?(user1.id, user2.id)
    end

    test "only recipient can accept request", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      # Requester tries to accept their own request
      assert {:error, :unauthorized} = Friends.accept_friend_request(request.id, user1.id)
    end

    test "can unfriend", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      {:ok, _} = Friends.accept_friend_request(request.id, user2.id)
      assert Friends.friends?(user1.id, user2.id)

      {:ok, _} = Friends.unfriend(user1.id, user2.id)
      refute Friends.friends?(user1.id, user2.id)
    end

    test "list_friends returns only accepted friends", %{user1: user1, user2: user2, user3: user3} do
      # Send and accept request from user2
      {:ok, request1} = Friends.send_friend_request(user1.id, user2.id)
      {:ok, _} = Friends.accept_friend_request(request1.id, user2.id)

      # Send but don't accept request from user3
      {:ok, _request2} = Friends.send_friend_request(user1.id, user3.id)

      friends = Friends.list_friends(user1.id)
      assert length(friends) == 1
      assert Enum.any?(friends, fn f -> f.id == user2.id end)
      refute Enum.any?(friends, fn f -> f.id == user3.id end)
    end

    test "list_pending_requests returns requests you received", %{
      user1: user1,
      user2: user2,
      user3: user3
    } do
      {:ok, _} = Friends.send_friend_request(user2.id, user1.id)
      {:ok, _} = Friends.send_friend_request(user3.id, user1.id)

      pending = Friends.list_pending_requests(user1.id)
      assert length(pending) == 2
    end

    test "list_sent_requests returns requests you sent", %{
      user1: user1,
      user2: user2,
      user3: user3
    } do
      {:ok, _} = Friends.send_friend_request(user1.id, user2.id)
      {:ok, _} = Friends.send_friend_request(user1.id, user3.id)

      sent = Friends.list_sent_requests(user1.id)
      assert length(sent) == 2
    end
  end

  describe "friend relationship status" do
    setup do
      user1 = user_fixture()
      user2 = user_fixture()

      %{user1: user1, user2: user2}
    end

    test "returns correct status for strangers", %{user1: user1, user2: user2} do
      status = Friends.get_relationship_status(user1.id, user2.id)
      refute status.are_friends
      assert is_nil(status.pending_request)
    end

    test "returns pending_request when request exists", %{user1: user1, user2: user2} do
      {:ok, _request} = Friends.send_friend_request(user1.id, user2.id)

      status = Friends.get_relationship_status(user1.id, user2.id)
      refute status.are_friends
      assert status.pending_request
    end

    test "returns are_friends when accepted", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      {:ok, _} = Friends.accept_friend_request(request.id, user2.id)

      status = Friends.get_relationship_status(user1.id, user2.id)
      assert status.are_friends
    end
  end

  describe "friend suggestions" do
    setup do
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()

      # Create mutual follows between user1 and user2
      Elektrine.Profiles.follow_user(user1.id, user2.id)
      Elektrine.Profiles.follow_user(user2.id, user1.id)

      %{user1: user1, user2: user2, user3: user3}
    end

    test "suggests mutual follows who aren't friends yet", %{user1: user1, user2: user2} do
      suggestions = Friends.get_suggested_friends(user1.id, 10)
      assert Enum.any?(suggestions, fn u -> u.id == user2.id end)
    end

    test "doesn't suggest existing friends", %{user1: user1, user2: user2} do
      {:ok, request} = Friends.send_friend_request(user1.id, user2.id)
      {:ok, _} = Friends.accept_friend_request(request.id, user2.id)

      suggestions = Friends.get_suggested_friends(user1.id, 10)
      refute Enum.any?(suggestions, fn u -> u.id == user2.id end)
    end
  end
end
