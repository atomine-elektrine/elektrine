defmodule Elektrine.Messaging.Membership do
  @moduledoc """
  Generic, schema-parameterized core for conversation member management shared
  by the chat (`Elektrine.Messaging.ChatConversations`) and social
  (`Elektrine.Social.Conversations`) contexts.

  After Phase 2 both member schemas expose an identical interface
  (`add_member_changeset/3`, `remove_member_changeset/1`, `changeset/2`, and the
  same fields), so the orchestration here works for both by taking the member
  and conversation schema modules as parameters. Federation publishing and
  authorization are already shared (`Elektrine.Messaging.Federation`,
  `Elektrine.Messaging.MembershipAuthz`), so they are called directly.

  Genuinely context-specific behaviour is NOT folded in here. In particular:

    * `builtin_room_role_definition/1` differs between contexts (different
      permission lists), so role-assignment publishing takes the definition
      lookup as a function argument (`role_def_fun`).

    * `update_member_count/3` handles the common group/channel teardown +
      member-count update; the social context's `"community"` archive branch is
      handled by an optional `on_empty` callback.

    * Predicates whose role lists differ (`admin?/2`) and per-context message
      schema queries stay in the contexts.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.Utils, as: FederationUtils
  alias Elektrine.Messaging.MembershipAuthz
  alias Elektrine.Repo

  @doc """
  Adds a member to a conversation. When `added_by_user_id` is supplied, enforces
  the manager authz check and the add-to-group privacy check before inserting.
  """
  def add_member(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        role,
        added_by_user_id
      ) do
    if added_by_user_id do
      with :ok <- ensure_can_manage_members(member_schema, conversation_id, added_by_user_id),
           {:ok, :allowed} <- Elektrine.Privacy.can_add_to_group?(added_by_user_id, user_id) do
        do_add_member(
          member_schema,
          conversation_schema,
          conversation_id,
          user_id,
          role,
          added_by_user_id,
          true
        )
      else
        {:error, reason} -> {:error, reason}
      end
    else
      do_add_member(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        role,
        nil,
        true
      )
    end
  end

  @doc "Adds a member without publishing federation membership state."
  def add_member_without_federation(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        role
      ) do
    do_add_member(
      member_schema,
      conversation_schema,
      conversation_id,
      user_id,
      role,
      nil,
      false
    )
  end

  @doc """
  Core add-member orchestration: bans, insert-or-reactivate, member-count
  update, federation publishing, and PubSub broadcasts.
  """
  def do_add_member(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        role,
        added_by_user_id,
        publish_federation?
      ) do
    if Elektrine.Messaging.Moderation.user_banned?(conversation_id, user_id) do
      {:error, :banned}
    else
      existing_member =
        Repo.get_by(member_schema, conversation_id: conversation_id, user_id: user_id)

      result =
        case existing_member do
          nil ->
            member_schema.add_member_changeset(conversation_id, user_id, role)
            |> Repo.insert()

          member ->
            member
            |> member_schema.changeset(%{
              left_at: nil,
              joined_at: DateTime.utc_now(),
              role: role
            })
            |> Repo.update()
        end

      case result do
        {:ok, member} ->
          update_member_count(member_schema, conversation_schema, conversation_id)

          maybe_publish_federation_membership(
            publish_federation?,
            conversation_id,
            user_id,
            added_by_user_id,
            role
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{conversation_id}",
            {:member_joined, %{user_id: user_id, conversation_id: conversation_id}}
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "user:#{user_id}",
            {:added_to_conversation, %{conversation_id: conversation_id}}
          )

          {:ok, member}

        error ->
          error
      end
    end
  end

  @doc """
  Removes a member from a conversation. An actor may remove a member if it is a
  manager (owner/admin/moderator) or it is removing itself; a nil actor skips
  the check (internal/self-service callers).
  """
  def remove_member(member_schema, conversation_schema, conversation_id, user_id, actor_user_id) do
    with :ok <-
           ensure_can_remove_member(member_schema, conversation_id, user_id, actor_user_id) do
      do_remove_member(member_schema, conversation_schema, conversation_id, user_id)
    end
  end

  @doc "Core remove-member orchestration."
  def do_remove_member(member_schema, conversation_schema, conversation_id, user_id) do
    member =
      from(cm in member_schema,
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
      )
      |> Repo.one()

    case member do
      nil ->
        {:error, :not_found}

      member ->
        member
        |> member_schema.remove_member_changeset()
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            update_member_count(member_schema, conversation_schema, conversation_id)

            _ =
              Federation.publish_membership_state(
                conversation_id,
                user_id,
                membership_state_for_departure(updated_member),
                updated_member.role || "member"
              )

            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "conversation:#{conversation_id}",
              {:member_left, %{user_id: user_id, conversation_id: conversation_id}}
            )

            {:ok, updated_member}

          error ->
            error
        end
    end
  end

  @doc "Gets an active conversation member record."
  def get_member(member_schema, conversation_id, user_id) do
    from(cm in member_schema,
      where:
        cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at)
    )
    |> Repo.one()
  end

  @doc "Gets all active members of a conversation with user details."
  def get_members(member_schema, conversation_id) do
    from(cm in member_schema,
      join: u in Elektrine.Accounts.User,
      on: u.id == cm.user_id,
      where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
      select: %{
        user_id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        verified: u.verified,
        joined_at: cm.joined_at,
        role: cm.role
      },
      order_by: [desc: cm.role, asc: cm.joined_at]
    )
    |> Repo.all()
  end

  @doc """
  Promotes a member to admin. Requires the promoter to be an admin of the
  conversation. `admin_fun` is the context's `admin?/2` predicate and
  `role_def_fun` its `builtin_room_role_definition/1` lookup.
  """
  def promote_to_admin(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        promoter_id,
        admin_fun,
        role_def_fun
      ) do
    with {:ok, _conversation} <- get_conversation_basic(conversation_schema, conversation_id),
         true <- admin_fun.(conversation_id, promoter_id) do
      member = get_member(member_schema, conversation_id, user_id)

      case member do
        nil ->
          {:error, :not_found}

        member ->
          member
          |> member_schema.changeset(%{role: "admin"})
          |> Repo.update()
          |> case do
            {:ok, updated_member} ->
              _ = Federation.publish_membership_state(conversation_id, user_id, "active", "admin")

              maybe_publish_role_assignment(
                conversation_schema,
                conversation_id,
                user_id,
                "admin",
                promoter_id,
                role_def_fun
              )

              {:ok, updated_member}

            error ->
              error
          end
      end
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc """
  Demotes an admin to member. Requires the demoter to be an admin and the target
  not to be the conversation creator.
  """
  def demote_from_admin(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        demoter_id,
        admin_fun,
        role_def_fun
      ) do
    with {:ok, conversation} <- get_conversation_basic(conversation_schema, conversation_id),
         true <- admin_fun.(conversation_id, demoter_id),
         false <- conversation.creator_id == user_id do
      member = get_member(member_schema, conversation_id, user_id)

      case member do
        nil ->
          {:error, :not_found}

        member ->
          member
          |> member_schema.changeset(%{role: "member"})
          |> Repo.update()
          |> case do
            {:ok, updated_member} ->
              _ =
                Federation.publish_membership_state(conversation_id, user_id, "active", "member")

              maybe_publish_role_assignment(
                conversation_schema,
                conversation_id,
                user_id,
                "member",
                demoter_id,
                role_def_fun
              )

              {:ok, updated_member}

            error ->
              error
          end
      end
    else
      true -> {:error, :cannot_demote_creator}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc """
  Updates a member's role. Enforces the stricter role-change authz and creator
  protection before updating.
  """
  def update_member_role(
        member_schema,
        conversation_schema,
        conversation_id,
        user_id,
        new_role,
        actor_user_id,
        role_def_fun
      ) do
    with :ok <- ensure_can_change_role(member_schema, conversation_id, actor_user_id),
         :ok <-
           ensure_not_protected_target(
             conversation_schema,
             conversation_id,
             user_id,
             actor_user_id
           ),
         member when not is_nil(member) <- get_member(member_schema, conversation_id, user_id) do
      member
      |> member_schema.changeset(%{role: new_role})
      |> Repo.update()
      |> case do
        {:ok, updated_member} ->
          _ = Federation.publish_membership_state(conversation_id, user_id, "active", new_role)

          maybe_publish_role_assignment(
            conversation_schema,
            conversation_id,
            user_id,
            new_role,
            actor_user_id,
            role_def_fun
          )

          {:ok, updated_member}

        error ->
          error
      end
    else
      nil -> {:error, :member_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Recomputes the conversation member count. Empty group/channel conversations
  are torn down (messages + members deleted, conversation removed). When the
  conversation is empty but not a deletable group/channel, the optional
  `on_empty` callback (arity 1, receiving the conversation) may handle it and
  return a result tuple; returning `nil` falls through to the normal count
  update.

  `message_schema` is the per-context message schema used for teardown.
  """
  def update_member_count(
        member_schema,
        conversation_schema,
        conversation_id,
        message_schema \\ nil,
        on_empty \\ nil
      ) do
    count =
      from(cm in member_schema,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: count()
      )
      |> Repo.one()

    conversation = Repo.get(conversation_schema, conversation_id)

    empty_result =
      if count == 0 && conversation && is_function(on_empty, 1),
        do: on_empty.(conversation),
        else: nil

    cond do
      count == 0 && conversation && conversation.type in ["group", "channel"] ->
        if message_schema do
          from(m in message_schema, where: m.conversation_id == ^conversation_id)
          |> Repo.delete_all()
        end

        from(cm in member_schema, where: cm.conversation_id == ^conversation_id)
        |> Repo.delete_all()

        Repo.delete(conversation)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversations:all",
          {:conversation_deleted, conversation_id}
        )

        {:deleted, 0}

      not is_nil(empty_result) ->
        empty_result

      true ->
        from(c in conversation_schema, where: c.id == ^conversation_id)
        |> Repo.update_all(set: [member_count: count])

        {:updated, count}
    end
  end

  @doc "Departure membership state for a member (currently always \"left\")."
  def membership_state_for_departure(%{role: role}) when role in ["owner", "admin"], do: "left"
  def membership_state_for_departure(_member), do: "left"

  @doc """
  Pins a conversation for a user. Returns `{:error, :unauthorized}` when the user
  is not an active member.
  """
  def pin(member_schema, conversation_id, user_id) do
    set_pinned(member_schema, conversation_id, user_id, true)
  end

  @doc """
  Unpins a conversation for a user. Returns `{:error, :unauthorized}` when the
  user is not an active member.
  """
  def unpin(member_schema, conversation_id, user_id) do
    set_pinned(member_schema, conversation_id, user_id, false)
  end

  defp set_pinned(member_schema, conversation_id, user_id, pinned) do
    case get_member(member_schema, conversation_id, user_id) do
      nil -> {:error, :unauthorized}
      member -> member |> member_schema.changeset(%{pinned: pinned}) |> Repo.update()
    end
  end

  @doc """
  Joins a public channel. Verifies the conversation is a public channel and the
  user is not already an active member, then delegates the actual join to
  `add_member_fun` (arity 3: `channel_id`, `user_id`, `role`).
  """
  def join_channel(member_schema, conversation_schema, channel_id, user_id, add_member_fun) do
    with {:ok, conversation} <- get_conversation_basic(conversation_schema, channel_id),
         true <- conversation.type == "channel",
         true <- conversation.is_public,
         nil <-
           from(cm in member_schema,
             where:
               cm.conversation_id == ^channel_id and cm.user_id == ^user_id and is_nil(cm.left_at)
           )
           |> Repo.one() do
      add_member_fun.(channel_id, user_id, "readonly")
    else
      false -> {:error, :not_public_channel}
      %{__struct__: ^member_schema} -> {:error, :already_member}
      error -> error
    end
  end

  # Authorization helpers ----------------------------------------------------

  @doc "Manager authz: owner/admin/moderator. Errors with :unauthorized."
  def ensure_can_manage_members(member_schema, conversation_id, actor_user_id) do
    if MembershipAuthz.can_manage_members?(
         get_member(member_schema, conversation_id, actor_user_id)
       ) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp ensure_can_remove_member(_member_schema, _conversation_id, _user_id, nil), do: :ok
  defp ensure_can_remove_member(_member_schema, _conversation_id, user_id, user_id), do: :ok

  defp ensure_can_remove_member(member_schema, conversation_id, _user_id, actor_user_id),
    do: ensure_can_manage_members(member_schema, conversation_id, actor_user_id)

  defp ensure_can_change_role(_member_schema, _conversation_id, nil), do: :ok

  defp ensure_can_change_role(member_schema, conversation_id, actor_user_id) do
    if MembershipAuthz.can_change_role?(get_member(member_schema, conversation_id, actor_user_id)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp ensure_not_protected_target(_conversation_schema, _conversation_id, _user_id, nil), do: :ok

  defp ensure_not_protected_target(conversation_schema, conversation_id, user_id, actor_user_id) do
    case get_conversation_basic(conversation_schema, conversation_id) do
      {:ok, conversation} ->
        if MembershipAuthz.protected_target?(conversation, user_id, actor_user_id) do
          {:error, :cannot_modify_creator}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp get_conversation_basic(conversation_schema, conversation_id) do
    case Repo.get(conversation_schema, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  # Federation publishing ----------------------------------------------------

  defp maybe_publish_invite_acceptance(_conversation_id, _user_id, nil, _role), do: :ok

  defp maybe_publish_invite_acceptance(conversation_id, user_id, added_by_user_id, role)
       when is_integer(conversation_id) and is_integer(user_id) and is_integer(added_by_user_id) do
    if user_id != added_by_user_id do
      Federation.publish_invite_state(
        conversation_id,
        user_id,
        added_by_user_id,
        "accepted",
        role,
        %{"source" => "local_member_add"}
      )
    else
      :ok
    end
  end

  defp maybe_publish_federation_membership(true, conversation_id, user_id, added_by_user_id, role) do
    maybe_publish_invite_acceptance(conversation_id, user_id, added_by_user_id, role)
    _ = Federation.publish_membership_state(conversation_id, user_id, "active", role)
    :ok
  end

  defp maybe_publish_federation_membership(false, _conversation_id, _user_id, _actor_id, _role),
    do: :ok

  # NOTE (latent federation divergence): with a nil actor this no-ops while the
  # caller still fires publish_membership_state with the new role, so mirrors
  # would receive the membership role without the matching role.upsert/
  # assignment events. This is currently unreachable (no caller invokes a role
  # change with a nil actor), so it is documented rather than reworked.
  defp maybe_publish_role_assignment(_conv_schema, _conversation_id, _user_id, _new_role, nil, _),
    do: :ok

  defp maybe_publish_role_assignment(
         conversation_schema,
         conversation_id,
         user_id,
         new_role,
         actor_user_id,
         role_def_fun
       )
       when is_integer(conversation_id) and is_integer(user_id) and is_binary(new_role) and
              is_integer(actor_user_id) do
    with %{type: "channel", server_id: server_id} <-
           Repo.get(conversation_schema, conversation_id),
         true <- is_integer(server_id),
         %Elektrine.Accounts.User{} = target_user <- Repo.get(Elektrine.Accounts.User, user_id),
         %Elektrine.Accounts.User{} = actor_user <-
           Repo.get(Elektrine.Accounts.User, actor_user_id),
         %{} = role_definition <- role_def_fun.(new_role) do
      role_upsert_payload = %{"role" => role_definition}

      role_assignment_payload = %{
        "assignment" => %{
          "role_id" => role_definition["id"],
          "target" => %{
            "type" => "member",
            "id" => FederationUtils.sender_payload(target_user)["uri"]
          },
          "state" => "assigned"
        }
      }

      _ =
        Federation.publish_extension_event(
          conversation_id,
          actor_user.id,
          "role.upsert",
          role_upsert_payload
        )

      _ =
        Federation.publish_extension_event(
          conversation_id,
          actor_user.id,
          "role.assignment.upsert",
          role_assignment_payload
        )
    end

    :ok
  end

  defp maybe_publish_role_assignment(_conv_schema, _cid, _uid, _new_role, _actor_user_id, _fun),
    do: :ok
end
