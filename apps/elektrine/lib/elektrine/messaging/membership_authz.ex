defmodule Elektrine.Messaging.MembershipAuthz do
  @moduledoc """
  Shared, security-critical authorization predicates for conversation member
  management. These role lists are the single source of truth for both the
  chat (`Elektrine.Messaging.ChatConversations`) and social
  (`Elektrine.Social.Conversations`) contexts; keeping them divergent in two
  places previously caused a real authz bug.

  Role semantics:

    * Member **management** (add/remove/kick members) is permitted for the
      roles `"owner"`, `"admin"`, and `"moderator"`. A moderator may move
      members in and out but must not be able to grant or revoke roles.

    * Role **changes** (granting/revoking roles, promoting/demoting) are
      stricter: only `"owner"` and `"admin"` may do so. This aligns with the
      `admin?/2` gate used by `promote_to_admin/3`.

    * The conversation **creator** is protected: their role may only be changed
      by the creator themselves (or by internal/federation callers with no
      local actor). This prevents an admin from demoting or seizing the owner.

  All functions are pure predicates that operate on already-fetched data (no
  Repo lookups). They use map patterns so they work for both member struct
  types (`ChatConversationMember` and `ConversationMember`). A `nil` member
  (no membership found) is treated as unauthorized.
  """

  @manage_roles ["owner", "admin", "moderator"]
  @role_change_roles ["owner", "admin"]

  @doc """
  Returns `true` when the given member may manage conversation membership
  (owner/admin/moderator). A `nil` member returns `false`.
  """
  def can_manage_members?(%{role: role}) when role in @manage_roles, do: true
  def can_manage_members?(_member), do: false

  @doc """
  Returns `true` when the given member may grant or revoke roles
  (owner/admin only). A `nil` member returns `false`.
  """
  def can_change_role?(%{role: role}) when role in @role_change_roles, do: true
  def can_change_role?(_member), do: false

  @doc """
  Returns `true` when `target_user_id` is the conversation creator and the
  actor is someone other than the creator, meaning the target's role is
  protected from modification.
  """
  def protected_target?(conversation, target_user_id, actor_user_id) do
    conversation.creator_id == target_user_id and conversation.creator_id != actor_user_id
  end
end
