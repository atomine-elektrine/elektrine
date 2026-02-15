defmodule Elektrine.Messaging.Moderation do
  @moduledoc """
  Context for moderation features - timeouts, kicks, bans, and moderation logs.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    ConversationMember,
    UserTimeout,
    ModerationAction,
    CommunityFlair,
    CommunityBan
  }

  ## User Timeouts

  @doc """
  Creates a timeout for a user in a specific conversation or globally.
  """
  def timeout_user(user_id, created_by_id, duration_seconds, opts \\ []) do
    conversation_id = Keyword.get(opts, :conversation_id)
    reason = Keyword.get(opts, :reason)

    timeout_until = DateTime.utc_now() |> DateTime.add(duration_seconds, :second)

    attrs = %{
      user_id: user_id,
      conversation_id: conversation_id,
      timeout_until: timeout_until,
      reason: reason,
      created_by_id: created_by_id
    }

    # Check if timeout already exists and delete it first
    remove_timeout(user_id, conversation_id)

    case %UserTimeout{}
         |> UserTimeout.changeset(attrs)
         |> Repo.insert() do
      {:ok, timeout} ->
        # Log the timeout action
        ModerationAction.log_action("timeout", user_id, created_by_id,
          conversation_id: conversation_id,
          reason: reason,
          duration: duration_seconds
        )

        # Broadcast timeout event
        broadcast_timeout_event(:timeout_added, timeout)

        {:ok, timeout}

      error ->
        error
    end
  end

  @doc """
  Checks if a user is currently timed out in a conversation or globally.
  """
  def user_timed_out?(user_id, conversation_id \\ nil) do
    now = DateTime.utc_now()

    query =
      from t in UserTimeout,
        where: t.user_id == ^user_id and t.timeout_until > ^now

    query =
      if conversation_id do
        where(query, [t], t.conversation_id == ^conversation_id or is_nil(t.conversation_id))
      else
        where(query, [t], is_nil(t.conversation_id))
      end

    Repo.exists?(query)
  end

  @doc """
  Batch check if multiple users are timed out in a conversation.
  Returns a map of user_id => boolean.

  This is much more efficient than calling user_timed_out?/2 for each user
  as it uses a single database query.
  """
  def users_timed_out(user_ids, conversation_id) when is_list(user_ids) do
    if Enum.empty?(user_ids) do
      %{}
    else
      now = DateTime.utc_now()

      # Get all active timeouts for these users (conversation-specific or global)
      timed_out_user_ids =
        from(t in UserTimeout,
          where:
            t.user_id in ^user_ids and
              t.timeout_until > ^now and
              (t.conversation_id == ^conversation_id or is_nil(t.conversation_id)),
          select: t.user_id
        )
        |> Repo.all()
        |> MapSet.new()

      # Build result map for all requested users
      user_ids
      |> Enum.map(fn user_id -> {user_id, MapSet.member?(timed_out_user_ids, user_id)} end)
      |> Map.new()
    end
  end

  @doc """
  Removes timeout for a user.
  """
  def remove_timeout(user_id, conversation_id \\ nil) do
    query =
      from t in UserTimeout,
        where: t.user_id == ^user_id

    query =
      if conversation_id do
        where(query, [t], t.conversation_id == ^conversation_id)
      else
        where(query, [t], is_nil(t.conversation_id))
      end

    # Get the timeout before deleting for broadcast
    timeout = Repo.one(query |> preload([:user, :conversation]))

    result = Repo.delete_all(query)

    # Broadcast removal if timeout existed
    if timeout do
      broadcast_timeout_event(:timeout_removed, timeout)
    end

    result
  end

  @doc """
  Gets active timeouts for a user.
  """
  def get_user_timeouts(user_id) do
    now = DateTime.utc_now()

    from(t in UserTimeout,
      where: t.user_id == ^user_id and t.timeout_until > ^now,
      preload: [:conversation, :created_by],
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Remove member from conversation (kick).
  """
  def remove_member(conversation_id, user_id, current_user) do
    # First remove from conversation
    member =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
      )
      |> Repo.one()

    case member do
      nil ->
        {:error, :not_found}

      member ->
        member
        |> ConversationMember.remove_member_changeset()
        |> Repo.update()
        |> case do
          {:ok, result} ->
            # Update member count
            update_member_count(conversation_id)

            # Log the kick action
            ModerationAction.log_action("kick", user_id, current_user.id,
              conversation_id: conversation_id,
              reason: "Kicked by admin"
            )

            # Broadcast kick event
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "conversation:#{conversation_id}",
              {:user_kicked, %{user_id: user_id, conversation_id: conversation_id}}
            )

            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "user:#{user_id}",
              {:kicked_from_conversation, %{conversation_id: conversation_id}}
            )

            # Also broadcast member_left event for consistency
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "conversation:#{conversation_id}",
              {:member_left, %{user_id: user_id, conversation_id: conversation_id}}
            )

            {:ok, result}

          error ->
            error
        end
    end
  end

  ## Bans

  @doc """
  Bans a user from a community.
  Only moderators can ban users.
  """
  def ban_user_from_community(
        community_id,
        user_id,
        banned_by_id,
        reason \\ nil,
        expires_at \\ nil
      ) do
    member = get_conversation_member(community_id, banned_by_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]

    if is_mod do
      # Don't allow banning moderators or owners
      target_member = get_conversation_member(community_id, user_id)

      if target_member && target_member.role in ["owner", "admin", "moderator"] do
        {:error, :cannot_ban_moderator}
      else
        attrs = %{
          conversation_id: community_id,
          user_id: user_id,
          banned_by_id: banned_by_id,
          reason: reason,
          expires_at: expires_at
        }

        %CommunityBan{}
        |> CommunityBan.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:banned_by_id, :reason, :expires_at, :updated_at]},
          conflict_target: [:conversation_id, :user_id]
        )
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Unbans a user from a community.
  Only moderators can unban users.
  """
  def unban_user_from_community(community_id, user_id, unbanned_by_id) do
    member = get_conversation_member(community_id, unbanned_by_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]

    if is_mod do
      from(b in CommunityBan,
        where: b.conversation_id == ^community_id and b.user_id == ^user_id
      )
      |> Repo.delete_all()

      {:ok, :unbanned}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Checks if a user is banned from a community.
  """
  def is_user_banned?(community_id, user_id) do
    now = DateTime.utc_now()

    from(b in CommunityBan,
      where:
        b.conversation_id == ^community_id and
          b.user_id == ^user_id and
          (is_nil(b.expires_at) or b.expires_at > ^now)
    )
    |> Repo.exists?()
  end

  @doc """
  Lists banned users for a community.
  """
  def list_community_bans(community_id) do
    now = DateTime.utc_now()

    from(b in CommunityBan,
      where:
        b.conversation_id == ^community_id and
          (is_nil(b.expires_at) or b.expires_at > ^now),
      preload: [:user, :banned_by]
    )
    |> Repo.all()
  end

  ## Moderation Log

  @doc """
  Gets moderation actions for a conversation or user.
  """
  def get_moderation_log(opts \\ []) do
    conversation_id = Keyword.get(opts, :conversation_id)
    target_user_id = Keyword.get(opts, :target_user_id)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from ma in ModerationAction,
        preload: [:target_user, :moderator, :conversation],
        order_by: [desc: ma.inserted_at],
        limit: ^limit

    query =
      if conversation_id do
        where(query, [ma], ma.conversation_id == ^conversation_id)
      else
        query
      end

    query =
      if target_user_id do
        where(query, [ma], ma.target_user_id == ^target_user_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Log a moderation action.
  """
  def log_moderation_action(action_type, target_user_id, moderator_id, opts \\ []) do
    ModerationAction.log_action(action_type, target_user_id, moderator_id, opts)
  end

  ## Community Flairs

  @doc """
  Lists all flairs for a community.
  """
  def list_community_flairs(community_id) do
    from(f in CommunityFlair,
      where: f.community_id == ^community_id,
      order_by: [asc: f.position, asc: f.name]
    )
    |> Repo.all()
  end

  @doc """
  Lists enabled flairs for a community.
  """
  def list_enabled_community_flairs(community_id) do
    from(f in CommunityFlair,
      where: f.community_id == ^community_id and f.is_enabled == true,
      order_by: [asc: f.position, asc: f.name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single community flair.
  """
  def get_community_flair!(id) do
    Repo.get!(CommunityFlair, id)
  end

  @doc """
  Lists flairs available to a user for a community.
  """
  def list_available_flairs(community_id, user_id) do
    # Check if user is a moderator
    member = get_conversation_member(community_id, user_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]

    query =
      from(f in CommunityFlair,
        where: f.community_id == ^community_id and f.is_enabled == true
      )

    # If not a mod, exclude mod-only flairs
    query =
      if is_mod do
        query
      else
        from f in query, where: f.is_mod_only == false
      end

    query
    |> order_by([f], asc: f.position, asc: f.name)
    |> Repo.all()
  end

  @doc """
  Gets a single flair.
  """
  def get_flair!(id), do: Repo.get!(CommunityFlair, id)

  @doc """
  Creates a flair for a community.
  """
  def create_community_flair(attrs \\ %{}) do
    %CommunityFlair{}
    |> CommunityFlair.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a flair.
  """
  def update_community_flair(%CommunityFlair{} = flair, attrs) do
    flair
    |> CommunityFlair.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a flair.
  """
  def delete_community_flair(%CommunityFlair{} = flair) do
    Repo.delete(flair)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking flair changes.
  """
  def change_community_flair(%CommunityFlair{} = flair, attrs \\ %{}) do
    CommunityFlair.changeset(flair, attrs)
  end

  ## Private Helpers

  defp get_conversation_member(conversation_id, user_id) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^conversation_id and
          cm.user_id == ^user_id and
          is_nil(cm.left_at)
    )
    |> Repo.one()
  end

  defp update_member_count(conversation_id) do
    count =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: count()
      )
      |> Repo.one()

    from(c in Elektrine.Messaging.Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [member_count: count])
  end

  defp broadcast_timeout_event(event_type, timeout) do
    # Broadcast to conversation if it's conversation-specific
    if timeout.conversation_id do
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{timeout.conversation_id}",
        {event_type, timeout}
      )
    end

    # Also broadcast globally for the user
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{timeout.user_id}",
      {event_type, timeout}
    )
  end
end
