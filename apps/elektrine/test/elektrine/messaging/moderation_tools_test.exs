defmodule Elektrine.Messaging.ModerationToolsTest do
  use Elektrine.DataCase

  alias Elektrine.Messaging.ModerationTools
  alias Elektrine.Messaging
  alias Elektrine.Accounts

  defp create_community(owner_id, name) do
    %Elektrine.Messaging.Conversation{}
    |> Elektrine.Messaging.Conversation.changeset(%{
      name: name,
      type: "community",
      is_public: true,
      created_by_id: owner_id
    })
    |> Repo.insert()
  end

  describe "thread locking" do
    setup do
      # Create test users
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, regular_user} =
        Accounts.create_user(%{
          username: "regular",
          password: "password123456",
          password_confirmation: "password123456"
        })

      # Create community
      {:ok, community} = create_community(owner.id, "testcommunity")

      # Add members with roles
      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")
      Messaging.add_member_to_conversation(community.id, regular_user.id, "member")

      # Create test message
      {:ok, message} = Messaging.create_text_message(community.id, regular_user.id, "Test post")

      %{
        owner: owner,
        moderator: moderator,
        regular_user: regular_user,
        community: community,
        message: message
      }
    end

    test "moderator can lock thread", %{moderator: moderator, message: message} do
      {:ok, locked_message} = ModerationTools.lock_thread(message.id, moderator.id, "Test lock")

      assert locked_message.locked_at != nil
      assert locked_message.locked_by_id == moderator.id
      assert locked_message.lock_reason == "Test lock"
      assert ModerationTools.thread_locked?(locked_message)
    end

    test "moderator can unlock thread", %{moderator: moderator, message: message} do
      {:ok, locked_message} = ModerationTools.lock_thread(message.id, moderator.id, "Test lock")
      {:ok, unlocked_message} = ModerationTools.unlock_thread(locked_message.id, moderator.id)

      assert unlocked_message.locked_at == nil
      assert unlocked_message.locked_by_id == nil
      refute ModerationTools.thread_locked?(unlocked_message)
    end

    test "regular user cannot lock thread", %{regular_user: regular_user, message: message} do
      assert {:error, :unauthorized} =
               ModerationTools.lock_thread(message.id, regular_user.id, "Test lock")
    end
  end

  describe "user timeouts" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner2",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator2",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, target_user} =
        Accounts.create_user(%{
          username: "target",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity2")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")

      %{moderator: moderator, target_user: target_user, community: community}
    end

    test "moderator can timeout user", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, timeout} =
        ModerationTools.timeout_user(community.id, target_user.id, moderator.id, 30, "Spam")

      assert timeout.user_id == target_user.id
      assert timeout.conversation_id == community.id
      assert timeout.reason == "Spam"
      assert ModerationTools.user_timed_out?(community.id, target_user.id)
    end

    test "moderator can remove timeout", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, _timeout} =
        ModerationTools.timeout_user(community.id, target_user.id, moderator.id, 30, "Spam")

      {:ok, :removed} = ModerationTools.remove_timeout(community.id, target_user.id, moderator.id)

      refute ModerationTools.user_timed_out?(community.id, target_user.id)
    end

    test "regular user cannot timeout others", %{target_user: target_user, community: community} do
      {:ok, regular} =
        Accounts.create_user(%{
          username: "regular3",
          password: "password123456",
          password_confirmation: "password123456"
        })

      Messaging.add_member_to_conversation(community.id, regular.id, "member")

      assert {:error, :unauthorized} =
               ModerationTools.timeout_user(community.id, target_user.id, regular.id, 30, "Test")
    end
  end

  describe "user warnings" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner3",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator3",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, target_user} =
        Accounts.create_user(%{
          username: "target2",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity3")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")
      Messaging.add_member_to_conversation(community.id, target_user.id, "member")

      %{moderator: moderator, target_user: target_user, community: community}
    end

    test "moderator can issue warning", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, warning} =
        ModerationTools.warn_user(
          community.id,
          target_user.id,
          moderator.id,
          "Violation of rules",
          severity: "low"
        )

      assert warning.user_id == target_user.id
      assert warning.reason == "Violation of rules"
      assert warning.severity == "low"
      assert warning.warned_by_id == moderator.id
    end

    test "3 warnings triggers auto-ban", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      # Issue 3 warnings
      {:ok, _w1} =
        ModerationTools.warn_user(community.id, target_user.id, moderator.id, "Warning 1",
          severity: "low"
        )

      {:ok, _w2} =
        ModerationTools.warn_user(community.id, target_user.id, moderator.id, "Warning 2",
          severity: "medium"
        )

      {:ok, _w3} =
        ModerationTools.warn_user(community.id, target_user.id, moderator.id, "Warning 3",
          severity: "high"
        )

      # Check if user is banned
      bans = Messaging.list_community_bans(community.id)
      assert length(bans) == 1
      assert List.first(bans).user_id == target_user.id
      assert List.first(bans).reason == "Auto-banned: 3 warnings received"
    end

    test "warning count is accurate", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, _w1} =
        ModerationTools.warn_user(community.id, target_user.id, moderator.id, "Warning 1")

      {:ok, _w2} =
        ModerationTools.warn_user(community.id, target_user.id, moderator.id, "Warning 2")

      assert ModerationTools.count_user_warnings(community.id, target_user.id) == 2
    end
  end

  describe "moderator notes" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner4",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator4",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, target_user} =
        Accounts.create_user(%{
          username: "target3",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity4")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")

      %{moderator: moderator, target_user: target_user, community: community}
    end

    test "moderator can add note", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, note} =
        ModerationTools.add_moderator_note(
          community.id,
          target_user.id,
          moderator.id,
          "Problematic user",
          true
        )

      assert note.note == "Problematic user"
      assert note.is_important == true
      assert note.created_by_id == moderator.id
    end

    test "can list notes for user", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, _note1} =
        ModerationTools.add_moderator_note(
          community.id,
          target_user.id,
          moderator.id,
          "Note 1",
          false
        )

      {:ok, _note2} =
        ModerationTools.add_moderator_note(
          community.id,
          target_user.id,
          moderator.id,
          "Note 2",
          true
        )

      notes = ModerationTools.list_moderator_notes(community.id, target_user.id)
      assert length(notes) == 2
      # Important notes should be first
      assert List.first(notes).is_important == true
    end

    test "moderator can delete note", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, note} =
        ModerationTools.add_moderator_note(
          community.id,
          target_user.id,
          moderator.id,
          "Test note",
          false
        )

      {:ok, _deleted} = ModerationTools.delete_moderator_note(note.id, moderator.id)

      notes = ModerationTools.list_moderator_notes(community.id, target_user.id)
      assert notes == []
    end
  end

  describe "auto-moderation rules" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner5",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator5",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity5")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")

      %{moderator: moderator, community: community}
    end

    test "can create auto-mod rule", %{moderator: moderator, community: community} do
      {:ok, rule} =
        ModerationTools.create_auto_mod_rule(%{
          conversation_id: community.id,
          name: "Spam Filter",
          rule_type: "keyword",
          pattern: "spam, scam",
          action: "remove",
          created_by_id: moderator.id
        })

      assert rule.name == "Spam Filter"
      assert rule.rule_type == "keyword"
      assert rule.enabled == true
    end

    test "keyword rule blocks matching content", %{moderator: moderator, community: community} do
      {:ok, _rule} =
        ModerationTools.create_auto_mod_rule(%{
          conversation_id: community.id,
          name: "Spam Filter",
          rule_type: "keyword",
          pattern: "spam, scam",
          action: "remove",
          created_by_id: moderator.id
        })

      assert {:blocked, _rule} =
               ModerationTools.check_auto_mod_rules(community.id, "This is spam content")

      assert {:ok, :allowed} =
               ModerationTools.check_auto_mod_rules(community.id, "This is clean content")
    end

    test "can toggle rule enabled status", %{moderator: moderator, community: community} do
      {:ok, rule} =
        ModerationTools.create_auto_mod_rule(%{
          conversation_id: community.id,
          name: "Test Rule",
          rule_type: "keyword",
          pattern: "test",
          action: "flag",
          created_by_id: moderator.id
        })

      {:ok, updated_rule} = ModerationTools.update_auto_mod_rule(rule, %{enabled: false})
      assert updated_rule.enabled == false
    end
  end

  describe "slow mode" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner6",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, user} =
        Accounts.create_user(%{
          username: "user6",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity6")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, user.id, "member")

      %{owner: owner, user: user, community: community}
    end

    test "slow mode allows first post", %{user: user, community: community, owner: owner} do
      # Enable slow mode
      {:ok, _conv} = ModerationTools.update_slow_mode(community.id, owner.id, 60)

      assert {:ok, :allowed} = ModerationTools.check_slow_mode(community.id, user.id)
    end

    test "slow mode blocks rapid posts", %{user: user, community: community, owner: owner} do
      # Enable slow mode (60 seconds)
      {:ok, _conv} = ModerationTools.update_slow_mode(community.id, owner.id, 60)

      # First post allowed
      {:ok, :allowed} = ModerationTools.check_slow_mode(community.id, user.id)
      {:ok, _timestamp} = ModerationTools.update_post_timestamp(community.id, user.id)

      # Second post blocked
      assert {:error, :slow_mode_active, _seconds} =
               ModerationTools.check_slow_mode(community.id, user.id)
    end
  end

  describe "approval queue" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner7",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator7",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, new_user} =
        Accounts.create_user(%{
          username: "newuser",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity7")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")
      Messaging.add_member_to_conversation(community.id, new_user.id, "member")

      {:ok, message} =
        Messaging.create_text_message(community.id, new_user.id, "Test post", nil,
          skip_broadcast: true
        )

      # Mark as pending
      message
      |> Elektrine.Messaging.Message.changeset(%{approval_status: "pending"})
      |> Repo.update()

      %{moderator: moderator, new_user: new_user, community: community, message: message}
    end

    test "moderator can approve post", %{moderator: moderator, message: message} do
      {:ok, approved_message} = ModerationTools.approve_post(message.id, moderator.id)

      assert approved_message.approval_status == "approved"
      assert approved_message.approved_by_id == moderator.id
    end

    test "moderator can reject post", %{moderator: moderator, message: message} do
      {:ok, rejected_message} =
        ModerationTools.reject_post(message.id, moderator.id, "Spam content")

      assert rejected_message.approval_status == "rejected"
      assert rejected_message.approved_by_id == moderator.id
    end

    test "new users need approval", %{
      new_user: new_user,
      community: community,
      moderator: moderator
    } do
      # Enable approval mode
      {:ok, _conv} = ModerationTools.update_approval_mode(community.id, moderator.id, true, 3)

      assert ModerationTools.needs_approval?(community.id, new_user.id) == true
    end

    test "users with enough posts don't need approval", %{
      new_user: new_user,
      community: community,
      moderator: moderator
    } do
      # Enable approval mode
      {:ok, _conv} = ModerationTools.update_approval_mode(community.id, moderator.id, true, 3)

      # Create and approve 3 posts
      Enum.each(1..3, fn i ->
        {:ok, msg} =
          Messaging.create_text_message(community.id, new_user.id, "Post #{i}", nil,
            skip_broadcast: true
          )

        msg
        |> Elektrine.Messaging.Message.changeset(%{approval_status: "approved"})
        |> Repo.update()
      end)

      assert ModerationTools.needs_approval?(community.id, new_user.id) == false
    end

    test "lists pending posts", %{community: community, message: message} do
      pending = ModerationTools.list_pending_posts(community.id)

      assert length(pending) == 1
      assert List.first(pending).id == message.id
    end
  end

  describe "moderation log" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner8",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, moderator} =
        Accounts.create_user(%{
          username: "moderator8",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, target_user} =
        Accounts.create_user(%{
          username: "target4",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, community} = create_community(owner.id, "testcommunity8")

      Messaging.add_member_to_conversation(community.id, owner.id, "owner")
      Messaging.add_member_to_conversation(community.id, moderator.id, "moderator")

      %{moderator: moderator, target_user: target_user, community: community}
    end

    test "logs moderation actions", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      {:ok, log_entry} =
        ModerationTools.log_moderation_action(
          community.id,
          moderator.id,
          target_user.id,
          nil,
          "ban",
          "Test reason",
          %{duration: 7}
        )

      assert log_entry.action_type == "ban"
      assert log_entry.moderator_id == moderator.id
      assert log_entry.target_user_id == target_user.id
      assert log_entry.reason == "Test reason"
    end

    test "retrieves moderation log", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      # Create multiple log entries
      ModerationTools.log_moderation_action(
        community.id,
        moderator.id,
        target_user.id,
        nil,
        "ban",
        "Reason 1"
      )

      ModerationTools.log_moderation_action(
        community.id,
        moderator.id,
        target_user.id,
        nil,
        "warn",
        "Reason 2"
      )

      log = ModerationTools.get_moderation_log(community.id)
      assert length(log) >= 2
    end

    test "can filter log by action type", %{
      moderator: moderator,
      target_user: target_user,
      community: community
    } do
      ModerationTools.log_moderation_action(
        community.id,
        moderator.id,
        target_user.id,
        nil,
        "ban",
        "Reason 1"
      )

      ModerationTools.log_moderation_action(
        community.id,
        moderator.id,
        target_user.id,
        nil,
        "warn",
        "Reason 2"
      )

      ban_logs = ModerationTools.get_moderation_log(community.id, action_type: "ban")
      assert Enum.all?(ban_logs, fn log -> log.action_type == "ban" end)
    end
  end

  describe "admin permissions" do
    setup do
      {:ok, owner} =
        Accounts.create_user(%{
          username: "owner9",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, admin} =
        Accounts.create_user(%{
          username: "siteadmin",
          password: "password123456",
          password_confirmation: "password123456"
        })

      {:ok, target_user} =
        Accounts.create_user(%{
          username: "target5",
          password: "password123456",
          password_confirmation: "password123456"
        })

      # Make admin a site admin
      admin
      |> Elektrine.Accounts.User.admin_changeset(%{is_admin: true})
      |> Repo.update!()

      # Reload admin to get fresh is_admin value
      admin = Repo.get!(Elektrine.Accounts.User, admin.id)

      {:ok, community} = create_community(owner.id, "testcommunity9")

      Messaging.add_member_to_conversation(community.id, target_user.id, "member")

      {:ok, message} = Messaging.create_text_message(community.id, target_user.id, "Test post")

      %{admin: admin, target_user: target_user, community: community, message: message}
    end

    test "site admin can lock threads without being community mod", %{
      admin: admin,
      message: message
    } do
      {:ok, locked_message} = ModerationTools.lock_thread(message.id, admin.id, "Admin lock")
      assert locked_message.locked_at != nil
    end

    test "site admin can timeout users without being community mod", %{
      admin: admin,
      target_user: target_user,
      community: community
    } do
      {:ok, timeout} =
        ModerationTools.timeout_user(community.id, target_user.id, admin.id, 30, "Admin timeout")

      assert timeout.user_id == target_user.id
    end

    test "site admin can issue warnings without being community mod", %{
      admin: admin,
      target_user: target_user,
      community: community
    } do
      {:ok, warning} =
        ModerationTools.warn_user(community.id, target_user.id, admin.id, "Admin warning")

      assert warning.user_id == target_user.id
    end

    test "site admin can add notes without being community mod", %{
      admin: admin,
      target_user: target_user,
      community: community
    } do
      {:ok, note} =
        ModerationTools.add_moderator_note(
          community.id,
          target_user.id,
          admin.id,
          "Admin note",
          false
        )

      assert note.note == "Admin note"
    end
  end
end
