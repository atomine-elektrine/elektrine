defmodule Elektrine.Messaging.MembershipCharacterizationTest do
  @moduledoc """
  CHARACTERIZATION tests pinning the CURRENT behavior of conversation member
  management in BOTH the chat context (`Elektrine.Messaging.ChatConversations`)
  and the social context (`Elektrine.Social.Conversations`).

  These exist to protect an upcoming refactor that will unify the two contexts.
  Every assertion captures what the code DOES today (return values / error
  atoms), not what would be "correct". If the behavior of the two contexts
  diverges, that divergence is documented here on purpose.
  """
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Messaging.ChatConversationMember
  alias Elektrine.Messaging.ChatConversations
  alias Elektrine.Social.ConversationMember
  alias Elektrine.Social.Conversations

  # The two contexts expose parallel APIs over different schemas. We
  # parameterize the test body over the context module + member struct so each
  # scenario is asserted against BOTH implementations and stays in lockstep.
  @contexts [
    {ChatConversations, ChatConversationMember, "chat"},
    {Conversations, ConversationMember, "social"}
  ]

  for {ctx, member_mod, label} <- @contexts do
    describe "#{label} context: group/channel creation" do
      test "create_group_conversation adds creator as admin and sets member_count" do
        ctx = unquote(ctx)
        creator = user_fixture()

        assert {:ok, group} =
                 ctx.create_group_conversation(creator.id, %{name: "Creation Group"})

        assert group.type == "group"

        creator_member = ctx.get_conversation_member(group.id, creator.id)
        assert creator_member.role == "admin"

        # member_count is updated within the creation transaction.
        reloaded = Elektrine.Repo.get!(group.__struct__, group.id)
        assert reloaded.member_count == 1
      end

      test "create_group_conversation with extra members counts all of them" do
        ctx = unquote(ctx)
        creator = user_fixture()
        m1 = user_fixture()
        m2 = user_fixture()

        assert {:ok, group} =
                 ctx.create_group_conversation(
                   creator.id,
                   %{name: "Group With Members"},
                   [m1.id, m2.id]
                 )

        members = ctx.get_conversation_members(group.id)
        assert length(members) == 3

        reloaded = Elektrine.Repo.get!(group.__struct__, group.id)
        assert reloaded.member_count == 3
      end

      test "create_channel adds creator as admin" do
        ctx = unquote(ctx)
        creator = user_fixture()

        assert {:ok, channel} =
                 ctx.create_channel(creator.id, %{name: "Creation Channel"})

        assert channel.type == "channel"

        creator_member = ctx.get_conversation_member(channel.id, creator.id)
        assert creator_member.role == "admin"

        reloaded = Elektrine.Repo.get!(channel.__struct__, channel.id)
        assert reloaded.member_count == 1
      end
    end

    describe "#{label} context: add_member_to_conversation/4" do
      test "nil actor (self/internal) succeeds" do
        ctx = unquote(ctx)
        creator = user_fixture()
        newcomer = user_fixture()

        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Add Nil Actor"})

        assert {:ok, member} =
                 ctx.add_member_to_conversation(group.id, newcomer.id, "member", nil)

        assert member.user_id == newcomer.id
        assert member.role == "member"
      end

      test "owner/admin actor succeeds" do
        ctx = unquote(ctx)
        creator = user_fixture()
        newcomer = user_fixture()

        # creator is stored as "admin" -> qualifies as a manager.
        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Add Admin Actor"})

        assert {:ok, member} =
                 ctx.add_member_to_conversation(group.id, newcomer.id, "member", creator.id)

        assert member.user_id == newcomer.id
      end

      test "non-manager (plain member) actor -> {:error, :unauthorized}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        plain_member = user_fixture()
        newcomer = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Add NonManager"}, [plain_member.id])

        # plain_member was added with role "member" -> not a manager.
        assert {:error, :unauthorized} =
                 ctx.add_member_to_conversation(group.id, newcomer.id, "member", plain_member.id)
      end

      test "moderator actor succeeds (moderator may manage members)" do
        ctx = unquote(ctx)
        creator = user_fixture()
        mod = user_fixture()
        newcomer = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Add Mod Actor"}, [mod.id])

        # Promote mod to moderator via nil-actor role change (skips authz).
        assert {:ok, _} = ctx.update_member_role(group.id, mod.id, "moderator", nil)

        assert {:ok, member} =
                 ctx.add_member_to_conversation(group.id, newcomer.id, "member", mod.id)

        assert member.user_id == newcomer.id
      end
    end

    describe "#{label} context: remove_member_from_conversation" do
      test "self-removal (actor == target) succeeds" do
        ctx = unquote(ctx)
        creator = user_fixture()
        leaver = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Remove Self"}, [leaver.id])

        assert {:ok, removed} =
                 ctx.remove_member_from_conversation(group.id, leaver.id, leaver.id)

        assert removed.user_id == leaver.id
        refute is_nil(removed.left_at)
        assert ctx.get_conversation_member(group.id, leaver.id) == nil
      end

      test "manager removing another member succeeds" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Remove By Manager"}, [target.id])

        assert {:ok, removed} =
                 ctx.remove_member_from_conversation(group.id, target.id, creator.id)

        assert removed.user_id == target.id
      end

      test "non-manager removing another member -> {:error, :unauthorized}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        plain_member = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(
            creator.id,
            %{name: "Remove By NonManager"},
            [plain_member.id, target.id]
          )

        assert {:error, :unauthorized} =
                 ctx.remove_member_from_conversation(group.id, target.id, plain_member.id)
      end

      test "nil actor succeeds (skips authz)" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Remove Nil Actor"}, [target.id])

        assert {:ok, removed} =
                 ctx.remove_member_from_conversation(group.id, target.id, nil)

        assert removed.user_id == target.id
      end

      test "arity/2 (no actor) succeeds, skipping authz" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Remove Arity2"}, [target.id])

        assert {:ok, removed} = ctx.remove_member_from_conversation(group.id, target.id)
        assert removed.user_id == target.id
      end
    end

    describe "#{label} context: update_member_role/4" do
      test "owner/admin actor can change roles" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Role Admin Actor"}, [target.id])

        assert {:ok, updated} =
                 ctx.update_member_role(group.id, target.id, "moderator", creator.id)

        assert updated.role == "moderator"
      end

      test "moderator actor -> {:error, :unauthorized} (role changes need owner/admin)" do
        ctx = unquote(ctx)
        creator = user_fixture()
        mod = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(
            creator.id,
            %{name: "Role Mod Actor"},
            [mod.id, target.id]
          )

        {:ok, _} = ctx.update_member_role(group.id, mod.id, "moderator", nil)

        assert {:error, :unauthorized} =
                 ctx.update_member_role(group.id, target.id, "moderator", mod.id)
      end

      test "non-creator admin changing the creator's role -> {:error, :cannot_modify_creator}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        other_admin = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(
            creator.id,
            %{name: "Role Protect Creator"},
            [other_admin.id]
          )

        # Make other_admin an admin (qualifies for role-change authz) via nil actor.
        {:ok, _} = ctx.update_member_role(group.id, other_admin.id, "admin", nil)

        assert {:error, :cannot_modify_creator} =
                 ctx.update_member_role(group.id, creator.id, "member", other_admin.id)
      end

      test "nil actor succeeds (skips authz and creator protection)" do
        ctx = unquote(ctx)
        creator = user_fixture()

        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Role Nil Actor"})

        # Even the creator's own role can be changed by a nil (internal) actor.
        assert {:ok, updated} =
                 ctx.update_member_role(group.id, creator.id, "moderator", nil)

        assert updated.role == "moderator"
      end

      test "arity/3 (no actor) behaves like nil actor" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Role Arity3"}, [target.id])

        assert {:ok, updated} = ctx.update_member_role(group.id, target.id, "moderator")
        assert updated.role == "moderator"
      end

      test "unknown member -> {:error, :member_not_found}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        stranger = user_fixture()

        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Role NoMember"})

        assert {:error, :member_not_found} =
                 ctx.update_member_role(group.id, stranger.id, "moderator", nil)
      end
    end

    describe "#{label} context: promote_to_admin/3 and demote_from_admin/3" do
      test "admin promoter can promote a member to admin" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Promote Admin"}, [target.id])

        assert {:ok, updated} = ctx.promote_to_admin(group.id, target.id, creator.id)
        assert updated.role == "admin"
      end

      test "non-admin promoter -> {:error, :unauthorized}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        promoter = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(
            creator.id,
            %{name: "Promote Unauth"},
            [promoter.id, target.id]
          )

        # promoter is a plain "member" -> admin?/2 is false.
        assert {:error, :unauthorized} =
                 ctx.promote_to_admin(group.id, target.id, promoter.id)
      end

      test "demote_from_admin demotes an admin back to member" do
        ctx = unquote(ctx)
        creator = user_fixture()
        target = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Demote Admin"}, [target.id])

        {:ok, _} = ctx.promote_to_admin(group.id, target.id, creator.id)

        assert {:ok, updated} = ctx.demote_from_admin(group.id, target.id, creator.id)
        assert updated.role == "member"
      end

      test "demote_from_admin on the creator -> {:error, :cannot_demote_creator}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        other_admin = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(
            creator.id,
            %{name: "Demote Creator"},
            [other_admin.id]
          )

        {:ok, _} = ctx.promote_to_admin(group.id, other_admin.id, creator.id)

        assert {:error, :cannot_demote_creator} =
                 ctx.demote_from_admin(group.id, creator.id, other_admin.id)
      end
    end

    describe "#{label} context: join_conversation / leave_conversation" do
      test "joining a public group adds the user as a member" do
        ctx = unquote(ctx)
        creator = user_fixture()
        joiner = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Public Group", is_public: true})

        assert {:ok, member} = ctx.join_conversation(group.id, joiner.id)
        assert member.user_id == joiner.id
        assert member.role == "member"
      end

      test "joining a non-public group -> {:error, :not_public_channel}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        joiner = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Private Group", is_public: false})

        assert {:error, :not_public_channel} = ctx.join_conversation(group.id, joiner.id)
      end

      test "joining a public channel adds the user as readonly" do
        ctx = unquote(ctx)
        creator = user_fixture()
        joiner = user_fixture()

        {:ok, channel} =
          ctx.create_channel(creator.id, %{name: "Public Channel", is_public: true})

        assert {:ok, member} = ctx.join_conversation(channel.id, joiner.id)
        assert member.role == "readonly"
      end

      test "joining when already a member -> {:error, :already_member}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        joiner = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Rejoin Group", is_public: true})

        {:ok, _} = ctx.join_conversation(group.id, joiner.id)
        assert {:error, :already_member} = ctx.join_conversation(group.id, joiner.id)
      end

      test "leaving as a non-creator member succeeds" do
        ctx = unquote(ctx)
        creator = user_fixture()
        leaver = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Leave Group"}, [leaver.id])

        assert {:ok, left} = ctx.leave_conversation(group.id, leaver.id)
        assert left.user_id == leaver.id
        refute is_nil(left.left_at)
      end

      test "creator leaving a group with other members -> {:error, :owner_must_transfer}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        other = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Owner Transfer"}, [other.id])

        assert {:error, :owner_must_transfer} = ctx.leave_conversation(group.id, creator.id)
      end

      test "leaving when not a member -> {:error, :not_a_member}" do
        ctx = unquote(ctx)
        creator = user_fixture()
        stranger = user_fixture()

        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Not A Member"})

        assert {:error, :not_a_member} = ctx.leave_conversation(group.id, stranger.id)
      end
    end

    describe "#{label} context: get_conversation_member(s) shapes" do
      test "get_conversation_member returns the member struct for an active member" do
        ctx = unquote(ctx)
        member_mod = unquote(member_mod)
        creator = user_fixture()

        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Member Shape"})

        member = ctx.get_conversation_member(group.id, creator.id)
        assert %^member_mod{} = member
        assert member.user_id == creator.id
        assert member.conversation_id == group.id
        assert member.role == "admin"
        assert is_nil(member.left_at)
      end

      test "get_conversation_member returns nil for a non-member" do
        ctx = unquote(ctx)
        creator = user_fixture()
        stranger = user_fixture()

        {:ok, group} = ctx.create_group_conversation(creator.id, %{name: "Member Nil Shape"})

        assert ctx.get_conversation_member(group.id, stranger.id) == nil
      end

      test "get_conversation_members returns plain maps with expected keys" do
        ctx = unquote(ctx)
        creator = user_fixture()
        other = user_fixture()

        {:ok, group} =
          ctx.create_group_conversation(creator.id, %{name: "Members List Shape"}, [other.id])

        members = ctx.get_conversation_members(group.id)
        assert length(members) == 2

        member = hd(members)
        assert is_map(member)
        refute is_struct(member)

        assert Map.keys(member) |> Enum.sort() ==
                 Enum.sort([
                   :user_id,
                   :username,
                   :handle,
                   :display_name,
                   :avatar,
                   :verified,
                   :joined_at,
                   :role
                 ])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Social-only helpers: promote_to_moderator/3 and demote_from_moderator/3.
  # The chat context has no parallel moderator helpers, so these are asserted
  # only against Elektrine.Social.Conversations.
  # ---------------------------------------------------------------------------
  describe "social context: promote_to_moderator/3 and demote_from_moderator/3" do
    test "owner/admin actor can promote a member to moderator" do
      creator = user_fixture()
      target = user_fixture()

      {:ok, group} =
        Conversations.create_group_conversation(creator.id, %{name: "Promote Mod"}, [target.id])

      assert {:ok, updated} = Conversations.promote_to_moderator(group.id, target.id, creator.id)
      assert updated.role == "moderator"
    end

    test "non-manager actor promoting to moderator -> {:error, :unauthorized}" do
      creator = user_fixture()
      plain = user_fixture()
      target = user_fixture()

      {:ok, group} =
        Conversations.create_group_conversation(
          creator.id,
          %{name: "Promote Mod Unauth"},
          [plain.id, target.id]
        )

      assert {:error, :unauthorized} =
               Conversations.promote_to_moderator(group.id, target.id, plain.id)
    end

    test "nil actor can promote to moderator (skips authz)" do
      creator = user_fixture()
      target = user_fixture()

      {:ok, group} =
        Conversations.create_group_conversation(
          creator.id,
          %{name: "Promote Mod Nil"},
          [target.id]
        )

      assert {:ok, updated} = Conversations.promote_to_moderator(group.id, target.id)
      assert updated.role == "moderator"
    end

    test "demote_from_moderator returns the member to member role" do
      creator = user_fixture()
      target = user_fixture()

      {:ok, group} =
        Conversations.create_group_conversation(
          creator.id,
          %{name: "Demote Mod"},
          [target.id]
        )

      {:ok, _} = Conversations.promote_to_moderator(group.id, target.id, creator.id)

      assert {:ok, updated} =
               Conversations.demote_from_moderator(group.id, target.id, creator.id)

      assert updated.role == "member"
    end
  end
end
