defmodule Elektrine.PrivacyTest do
  use Elektrine.DataCase

  alias Elektrine.{Accounts, Friends, Privacy, Repo}

  describe "can_send_dm?/2" do
    setup do
      {:ok, sender} = create_user("sender")
      {:ok, recipient} = create_user("recipient")
      %{sender: sender, recipient: recipient}
    end

    test "allows DM when set to everyone", %{sender: sender, recipient: recipient} do
      {:ok, updated} = Accounts.update_user(recipient, %{allow_direct_messages_from: "everyone"})
      assert {:ok, :allowed} = Privacy.can_send_dm?(sender.id, updated.id)
    end

    test "blocks DM when set to nobody", %{sender: sender, recipient: recipient} do
      {:ok, updated} = Accounts.update_user(recipient, %{allow_direct_messages_from: "nobody"})
      assert {:error, :privacy_restricted} = Privacy.can_send_dm?(sender.id, updated.id)
    end

    test "allows DM when set to friends and users are friends", %{
      sender: sender,
      recipient: recipient
    } do
      {:ok, updated} = Accounts.update_user(recipient, %{allow_direct_messages_from: "friends"})
      make_friends(sender.id, recipient.id)
      assert {:ok, :allowed} = Privacy.can_send_dm?(sender.id, updated.id)
    end

    test "blocks DM when set to friends and users are not friends", %{
      sender: sender,
      recipient: recipient
    } do
      {:ok, updated} = Accounts.update_user(recipient, %{allow_direct_messages_from: "friends"})
      assert {:error, :privacy_restricted} = Privacy.can_send_dm?(sender.id, updated.id)
    end

    test "blocks DM when either user has blocked the other", %{
      sender: sender,
      recipient: recipient
    } do
      Accounts.block_user(sender.id, recipient.id)
      assert {:error, :blocked} = Privacy.can_send_dm?(sender.id, recipient.id)
    end

    test "prevents self-DM", %{sender: sender} do
      assert {:error, :cannot_dm_self} = Privacy.can_send_dm?(sender.id, sender.id)
    end
  end

  describe "can_call?/2" do
    setup do
      {:ok, caller} = create_user("caller")
      {:ok, callee} = create_user("callee")
      %{caller: caller, callee: callee}
    end

    test "allows call when set to everyone", %{caller: caller, callee: callee} do
      {:ok, updated} = Accounts.update_user(callee, %{allow_calls_from: "everyone"})
      assert {:ok, :allowed} = Privacy.can_call?(caller.id, updated.id)
    end

    test "blocks call when set to nobody", %{caller: caller, callee: callee} do
      {:ok, updated} = Accounts.update_user(callee, %{allow_calls_from: "nobody"})
      assert {:error, :privacy_restricted} = Privacy.can_call?(caller.id, updated.id)
    end

    test "allows call when set to friends and users are friends", %{
      caller: caller,
      callee: callee
    } do
      make_friends(caller.id, callee.id)
      assert {:ok, :allowed} = Privacy.can_call?(caller.id, callee.id)
    end

    test "blocks call when set to friends and users are not friends", %{
      caller: caller,
      callee: callee
    } do
      # Default is friends
      assert {:error, :privacy_restricted} = Privacy.can_call?(caller.id, callee.id)
    end

    test "prevents self-call", %{caller: caller} do
      assert {:error, :cannot_call_self} = Privacy.can_call?(caller.id, caller.id)
    end
  end

  describe "can_send_friend_request?/2" do
    setup do
      {:ok, requester} = create_user("requester")
      {:ok, recipient} = create_user("recipient")
      %{requester: requester, recipient: recipient}
    end

    test "allows request when set to everyone", %{requester: requester, recipient: recipient} do
      {:ok, updated} = Accounts.update_user(recipient, %{allow_friend_requests_from: "everyone"})
      assert {:ok, :allowed} = Privacy.can_send_friend_request?(requester.id, updated.id)
    end

    test "blocks request when set to nobody", %{requester: requester, recipient: recipient} do
      {:ok, updated} = Accounts.update_user(recipient, %{allow_friend_requests_from: "nobody"})

      assert {:error, :privacy_restricted} =
               Privacy.can_send_friend_request?(requester.id, updated.id)
    end

    test "prevents request when already friends", %{requester: requester, recipient: recipient} do
      make_friends(requester.id, recipient.id)

      assert {:error, :already_friends} =
               Privacy.can_send_friend_request?(requester.id, recipient.id)
    end

    test "prevents self-friend request", %{requester: requester} do
      assert {:error, :cannot_friend_self} =
               Privacy.can_send_friend_request?(requester.id, requester.id)
    end

    test "blocks accepting request after privacy changed to nobody", %{
      requester: requester,
      recipient: recipient
    } do
      # Send request when privacy allows it
      {:ok, request} = Friends.send_friend_request(requester.id, recipient.id)

      # Change privacy to nobody
      {:ok, _updated} = Accounts.update_user(recipient, %{allow_friend_requests_from: "nobody"})

      # Attempt to accept - should be blocked and auto-rejected
      assert {:error, :privacy_settings_changed} =
               Friends.accept_friend_request(request.id, recipient.id)

      # Verify request was auto-rejected
      updated_request = Repo.get(Friends.FriendRequest, request.id)
      assert updated_request.status == "rejected"
    end
  end

  describe "can_add_to_group?/2" do
    setup do
      {:ok, adder} = create_user("adder")
      {:ok, target} = create_user("targetuser")
      %{adder: adder, target: target}
    end

    test "allows add when set to everyone", %{adder: adder, target: target} do
      {:ok, updated} = Accounts.update_user(target, %{allow_group_adds_from: "everyone"})
      assert {:ok, :allowed} = Privacy.can_add_to_group?(adder.id, updated.id)
    end

    test "blocks add when set to nobody", %{adder: adder, target: target} do
      {:ok, updated} = Accounts.update_user(target, %{allow_group_adds_from: "nobody"})
      assert {:error, :privacy_restricted} = Privacy.can_add_to_group?(adder.id, updated.id)
    end

    test "allows self-add", %{adder: adder} do
      assert {:ok, :allowed} = Privacy.can_add_to_group?(adder.id, adder.id)
    end
  end

  describe "can_view_profile?/2" do
    setup do
      {:ok, viewer} = create_user("viewer")
      {:ok, owner} = create_user("owner")
      %{viewer: viewer, owner: owner}
    end

    test "allows viewing public profiles", %{viewer: viewer, owner: owner} do
      {:ok, updated} = Accounts.update_user(owner, %{profile_visibility: "public"})
      assert {:ok, :allowed} = Privacy.can_view_profile?(viewer.id, updated.id)
    end

    test "blocks viewing private profiles", %{viewer: viewer, owner: owner} do
      {:ok, updated} = Accounts.update_user(owner, %{profile_visibility: "private"})
      assert {:error, :privacy_restricted} = Privacy.can_view_profile?(viewer.id, updated.id)
    end

    test "allows viewing own profile", %{owner: owner} do
      {:ok, updated} = Accounts.update_user(owner, %{profile_visibility: "private"})
      assert {:ok, :allowed} = Privacy.can_view_profile?(updated.id, updated.id)
    end
  end

  # Test helpers

  defp create_user(username) do
    Accounts.create_user(%{
      username: username,
      password: "password123456",
      password_confirmation: "password123456"
    })
  end

  defp make_friends(user1_id, user2_id) do
    {:ok, request} = Friends.send_friend_request(user1_id, user2_id)
    {:ok, _} = Friends.accept_friend_request(request.id, user2_id)
    :ok
  end
end
