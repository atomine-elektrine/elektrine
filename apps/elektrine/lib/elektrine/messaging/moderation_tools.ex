defmodule Elektrine.Messaging.ModerationTools do
  @moduledoc """
  Comprehensive moderation tools for community management.
  """
  import Ecto.Query
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    AutoModRule,
    Conversation,
    Message,
    ModeratorNote,
    UserPostTimestamp,
    UserWarning
  }

  # ====== THREAD LOCKING ======

  @doc """
  Locks a thread to prevent new replies.
  """
  def lock_thread(message_id, moderator_id, reason \\ nil) do
    message = Repo.get!(Message, message_id)
    member = Elektrine.Messaging.get_conversation_member(message.conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      case message
           |> Ecto.Changeset.change(%{
             locked_at: DateTime.utc_now() |> DateTime.truncate(:second),
             locked_by_id: moderator_id,
             lock_reason: reason
           })
           |> Repo.update() do
        {:ok, updated_message} ->
          log_moderation_action(
            message.conversation_id,
            moderator_id,
            nil,
            message_id,
            "lock",
            reason
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:thread_locked, updated_message}
          )

          {:ok, updated_message}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Unlocks a locked thread.
  """
  def unlock_thread(message_id, moderator_id) do
    message = Repo.get!(Message, message_id)
    member = Elektrine.Messaging.get_conversation_member(message.conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      case message
           |> Ecto.Changeset.change(%{
             locked_at: nil,
             locked_by_id: nil,
             lock_reason: nil
           })
           |> Repo.update() do
        {:ok, updated_message} ->
          log_moderation_action(
            message.conversation_id,
            moderator_id,
            nil,
            message_id,
            "unlock",
            nil
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:thread_unlocked, updated_message}
          )

          {:ok, updated_message}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Checks if a thread is locked.
  """
  def thread_locked?(%Message{locked_at: nil}), do: false
  def thread_locked?(%Message{locked_at: _}), do: true

  # ====== USER TIMEOUTS/MUTES ======

  @doc """
  Timeout/mute a user in a community.
  """
  def timeout_user(conversation_id, user_id, moderator_id, duration_minutes, reason \\ nil) do
    member = Elektrine.Messaging.get_conversation_member(conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      expires_at = DateTime.add(DateTime.utc_now(), duration_minutes * 60, :second)

      # Delete any existing timeout first
      from(t in Elektrine.Messaging.UserTimeout,
        where: t.conversation_id == ^conversation_id and t.user_id == ^user_id
      )
      |> Repo.delete_all()

      # Create new timeout
      attrs = %{
        user_id: user_id,
        conversation_id: conversation_id,
        timeout_until: expires_at,
        reason: reason,
        created_by_id: moderator_id
      }

      case %Elektrine.Messaging.UserTimeout{}
           |> Elektrine.Messaging.UserTimeout.changeset(attrs)
           |> Repo.insert() do
        {:ok, timeout} ->
          log_moderation_action(conversation_id, moderator_id, user_id, nil, "timeout", reason, %{
            duration_minutes: duration_minutes
          })

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{conversation_id}",
            {:user_timed_out, timeout}
          )

          {:ok, timeout}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Remove a timeout from a user.
  """
  def remove_timeout(conversation_id, user_id, moderator_id) do
    member = Elektrine.Messaging.get_conversation_member(conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      {count, _} =
        from(t in Elektrine.Messaging.UserTimeout,
          where: t.conversation_id == ^conversation_id and t.user_id == ^user_id
        )
        |> Repo.delete_all()

      if count > 0 do
        log_moderation_action(conversation_id, moderator_id, user_id, nil, "remove_timeout", nil)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{conversation_id}",
          {:timeout_removed, user_id}
        )

        {:ok, :removed}
      else
        {:error, :not_found}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Check if a user is currently timed out in a community.
  """
  def user_timed_out?(conversation_id, user_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from t in Elektrine.Messaging.UserTimeout,
        where:
          t.conversation_id == ^conversation_id and
            t.user_id == ^user_id and
            t.timeout_until > ^now
    )
  end

  # ====== USER WARNINGS ======

  @doc """
  Issue a warning to a user.
  """
  def warn_user(conversation_id, user_id, moderator_id, reason, opts \\ []) do
    member = Elektrine.Messaging.get_conversation_member(conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      severity = Keyword.get(opts, :severity, "low")
      message_id = Keyword.get(opts, :message_id)

      attrs = %{
        conversation_id: conversation_id,
        user_id: user_id,
        warned_by_id: moderator_id,
        reason: reason,
        severity: severity,
        related_message_id: message_id
      }

      case %UserWarning{}
           |> UserWarning.changeset(attrs)
           |> Repo.insert() do
        {:ok, warning} ->
          log_moderation_action(
            conversation_id,
            moderator_id,
            user_id,
            message_id,
            "warn",
            reason,
            %{severity: severity}
          )

          # Check for auto-escalation (3+ warnings = temp ban)
          warning_count = count_user_warnings(conversation_id, user_id)

          if warning_count >= 3 do
            # Auto-ban for 7 days
            Elektrine.Messaging.ban_user_from_community(
              conversation_id,
              user_id,
              moderator_id,
              "Auto-banned: 3 warnings received",
              DateTime.add(DateTime.utc_now(), 7 * 24 * 60 * 60, :second)
            )
          end

          {:ok, warning}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Get warnings for a user in a community.
  """
  def list_user_warnings(conversation_id, user_id) do
    from(w in UserWarning,
      where: w.conversation_id == ^conversation_id and w.user_id == ^user_id,
      order_by: [desc: w.inserted_at],
      preload: [:warned_by, :related_message]
    )
    |> Repo.all()
  end

  @doc """
  Count unacknowledged warnings for a user.
  """
  def count_user_warnings(conversation_id, user_id) do
    from(w in UserWarning,
      where:
        w.conversation_id == ^conversation_id and
          w.user_id == ^user_id and
          is_nil(w.acknowledged_at)
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Mark a warning as acknowledged.
  """
  def acknowledge_warning(warning_id) do
    warning = Repo.get!(UserWarning, warning_id)

    warning
    |> Ecto.Changeset.change(%{acknowledged_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # ====== MODERATOR NOTES ======

  @doc """
  Add a private moderator note about a user.
  """
  def add_moderator_note(
        conversation_id,
        target_user_id,
        moderator_id,
        note,
        is_important \\ false
      ) do
    # Check if user is a community moderator or site admin
    member = Elektrine.Messaging.get_conversation_member(conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      %ModeratorNote{}
      |> ModeratorNote.changeset(%{
        conversation_id: conversation_id,
        target_user_id: target_user_id,
        created_by_id: moderator_id,
        note: note,
        is_important: is_important
      })
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Get all moderator notes for a user in a community.
  """
  def list_moderator_notes(conversation_id, target_user_id) do
    from(n in ModeratorNote,
      where: n.conversation_id == ^conversation_id and n.target_user_id == ^target_user_id,
      order_by: [desc: n.is_important, desc: n.inserted_at],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc """
  Delete a moderator note.
  """
  def delete_moderator_note(note_id, moderator_id) do
    note = Repo.get!(ModeratorNote, note_id)
    member = Elektrine.Messaging.get_conversation_member(note.conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      Repo.delete(note)
    else
      {:error, :unauthorized}
    end
  end

  # ====== AUTO-MODERATION RULES ======

  @doc """
  Create an auto-moderation rule.
  """
  def create_auto_mod_rule(attrs) do
    %AutoModRule{}
    |> AutoModRule.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update an auto-moderation rule.
  """
  def update_auto_mod_rule(rule, attrs) do
    rule
    |> AutoModRule.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  List auto-moderation rules for a community.
  """
  def list_auto_mod_rules(conversation_id) do
    from(r in AutoModRule,
      where: r.conversation_id == ^conversation_id,
      order_by: [desc: r.inserted_at],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc """
  Check content against auto-mod rules.
  Returns {:ok, :allowed} | {:flagged, rule} | {:blocked, rule}
  """
  def check_auto_mod_rules(conversation_id, content) do
    rules =
      from(r in AutoModRule,
        where: r.conversation_id == ^conversation_id and r.enabled == true
      )
      |> Repo.all()

    Enum.reduce_while(rules, {:ok, :allowed}, fn rule, _acc ->
      if matches_rule?(content, rule) do
        case rule.action do
          "remove" -> {:halt, {:blocked, rule}}
          "hold_for_review" -> {:halt, {:hold, rule}}
          "flag" -> {:halt, {:flagged, rule}}
          _ -> {:cont, {:ok, :allowed}}
        end
      else
        {:cont, {:ok, :allowed}}
      end
    end)
  end

  defp matches_rule?(content, %AutoModRule{rule_type: "keyword", pattern: pattern}) do
    keywords = String.split(pattern, ",") |> Enum.map(&String.trim/1)
    lower_content = String.downcase(content)

    Enum.any?(keywords, fn keyword ->
      String.contains?(lower_content, String.downcase(keyword))
    end)
  end

  defp matches_rule?(content, %AutoModRule{rule_type: "link_domain", pattern: pattern}) do
    domains = String.split(pattern, ",") |> Enum.map(&String.trim/1)

    Enum.any?(domains, fn domain ->
      String.contains?(content, domain)
    end)
  end

  defp matches_rule?(_content, _rule), do: false

  # ====== SLOW MODE ======

  @doc """
  Check if a user can post in slow mode.
  Returns {:ok, :allowed} | {:error, :slow_mode_active, seconds_remaining}
  """
  def check_slow_mode(conversation_id, user_id) do
    conversation = Repo.get!(Conversation, conversation_id)

    if conversation.slow_mode_seconds > 0 do
      case Repo.get_by(UserPostTimestamp, conversation_id: conversation_id, user_id: user_id) do
        nil ->
          {:ok, :allowed}

        timestamp ->
          time_since_last = DateTime.diff(DateTime.utc_now(), timestamp.last_post_at, :second)

          if time_since_last >= conversation.slow_mode_seconds do
            {:ok, :allowed}
          else
            {:error, :slow_mode_active, conversation.slow_mode_seconds - time_since_last}
          end
      end
    else
      {:ok, :allowed}
    end
  end

  @doc """
  Update user's last post timestamp for slow mode.
  """
  def update_post_timestamp(conversation_id, user_id) do
    %UserPostTimestamp{}
    |> UserPostTimestamp.changeset(%{
      conversation_id: conversation_id,
      user_id: user_id,
      last_post_at: DateTime.utc_now()
    })
    |> Repo.insert(
      on_conflict: {:replace, [:last_post_at]},
      conflict_target: [:conversation_id, :user_id]
    )
  end

  # ====== APPROVAL QUEUE ======

  @doc """
  Check if a post needs approval.
  """
  def needs_approval?(conversation_id, user_id) do
    conversation = Repo.get!(Conversation, conversation_id)

    if conversation.approval_mode_enabled do
      # Check if user has enough approved posts
      approved_count =
        from(m in Message,
          where:
            m.conversation_id == ^conversation_id and
              m.sender_id == ^user_id and
              m.approval_status == "approved"
        )
        |> Repo.aggregate(:count)

      approved_count < conversation.approval_threshold_posts
    else
      false
    end
  end

  @doc """
  Approve a post.
  """
  def approve_post(message_id, moderator_id) do
    message = Repo.get!(Message, message_id)
    member = Elektrine.Messaging.get_conversation_member(message.conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      case message
           |> Ecto.Changeset.change(%{
             approval_status: "approved",
             approved_by_id: moderator_id,
             approved_at: DateTime.utc_now() |> DateTime.truncate(:second)
           })
           |> Repo.update() do
        {:ok, updated_message} ->
          log_moderation_action(
            message.conversation_id,
            moderator_id,
            message.sender_id,
            message_id,
            "approve",
            nil
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:post_approved, updated_message}
          )

          {:ok, updated_message}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Reject a post.
  """
  def reject_post(message_id, moderator_id, reason \\ nil) do
    message = Repo.get!(Message, message_id)
    member = Elektrine.Messaging.get_conversation_member(message.conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      case message
           |> Ecto.Changeset.change(%{
             approval_status: "rejected",
             approved_by_id: moderator_id,
             approved_at: DateTime.utc_now() |> DateTime.truncate(:second)
           })
           |> Repo.update() do
        {:ok, updated_message} ->
          log_moderation_action(
            message.conversation_id,
            moderator_id,
            message.sender_id,
            message_id,
            "reject",
            reason
          )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:post_rejected, updated_message}
          )

          {:ok, updated_message}

        error ->
          error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  List pending posts awaiting approval.
  """
  def list_pending_posts(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id and m.approval_status == "pending",
      order_by: [asc: m.inserted_at],
      preload: [:sender, :flair, :poll, :link_preview, sender: :profile, poll: [options: []]]
    )
    |> Repo.all()
  end

  # ====== MODERATION LOG ======

  @doc """
  Log a moderation action to the audit trail.
  """
  def log_moderation_action(
        conversation_id,
        moderator_id,
        target_user_id,
        target_message_id,
        action_type,
        reason,
        metadata \\ %{}
      ) do
    %Elektrine.Messaging.ModerationAction{}
    |> Elektrine.Messaging.ModerationAction.changeset(%{
      conversation_id: conversation_id,
      moderator_id: moderator_id,
      target_user_id: target_user_id,
      target_message_id: target_message_id,
      action_type: action_type,
      reason: reason,
      details: metadata
    })
    |> Repo.insert()
  end

  @doc """
  Get moderation log for a community.
  """
  def get_moderation_log(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    action_type = Keyword.get(opts, :action_type)

    query =
      from(a in Elektrine.Messaging.ModerationAction,
        where: a.conversation_id == ^conversation_id,
        order_by: [desc: a.inserted_at],
        limit: ^limit,
        preload: [:moderator, :target_user]
      )

    query =
      if action_type do
        from a in query, where: a.action_type == ^action_type
      else
        query
      end

    Repo.all(query)
  end

  # ====== COMMUNITY SETTINGS ======

  @doc """
  Update slow mode for a community.
  """
  def update_slow_mode(conversation_id, moderator_id, seconds) do
    conversation = Repo.get!(Conversation, conversation_id)
    member = Elektrine.Messaging.get_conversation_member(conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      conversation
      |> Ecto.Changeset.change(%{slow_mode_seconds: seconds})
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Toggle approval mode for a community.
  """
  def update_approval_mode(conversation_id, moderator_id, enabled, threshold \\ 3) do
    conversation = Repo.get!(Conversation, conversation_id)
    member = Elektrine.Messaging.get_conversation_member(conversation_id, moderator_id)
    is_mod = member && member.role in ["moderator", "admin", "owner"]
    user = Repo.get(Elektrine.Accounts.User, moderator_id)
    is_admin = user && user.is_admin

    if is_mod || is_admin do
      conversation
      |> Ecto.Changeset.change(%{
        approval_mode_enabled: enabled,
        approval_threshold_posts: threshold
      })
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  # ====== BULK ACTIONS ======

  @doc """
  Bulk delete messages by IDs.
  """
  def bulk_delete_messages(message_ids, moderator_id) when is_list(message_ids) do
    Enum.map(message_ids, fn message_id ->
      Elektrine.Messaging.delete_message(message_id, moderator_id)
    end)
  end

  @doc """
  Bulk approve posts.
  """
  def bulk_approve_posts(message_ids, moderator_id) when is_list(message_ids) do
    Enum.map(message_ids, fn message_id ->
      approve_post(message_id, moderator_id)
    end)
  end
end
