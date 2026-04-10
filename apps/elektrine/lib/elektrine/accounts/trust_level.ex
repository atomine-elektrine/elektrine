defmodule Elektrine.Accounts.TrustLevel do
  @moduledoc """
  Trust level system similar to Discourse.

  Trust Levels:
  - TL0 (New): Default for all new users
  - TL1 (Basic): Established account with repeat logins and visits
  - TL2 (Member): Active participant
  - TL3 (Regular): Trusted community member with sustained engagement
  - TL4 (Leader): Manually granted, full moderation access
  """

  import Ecto.Query
  alias Elektrine.Accounts.{TrustLevelLog, User, UserActivityStats}
  alias Elektrine.Repo
  require Logger

  @levels %{
    0 => %{name: "New", color: "gray", description: "Welcome! Start exploring."},
    1 => %{name: "Basic", color: "blue", description: "You've learned the basics."},
    2 => %{name: "Member", color: "green", description: "Active community member."},
    3 => %{
      name: "Regular",
      color: "purple",
      description: "Trusted regular with moderation powers."
    },
    4 => %{name: "Leader", color: "red", description: "Community leader."}
  }

  # Trust levels only depend on signals that are currently tracked in production.
  @requirements %{
    1 => %{
      minimums: %{
        account_age_days: 1,
        login_count: 2,
        days_visited: 2,
        topics_entered: 5,
        posts_read: 30,
        time_read_seconds: 600
      },
      maximums: %{
        banned: 0,
        suspended: 0
      }
    },
    2 => %{
      minimums: %{
        account_age_days: 14,
        login_count: 5,
        days_visited: 15,
        topics_entered: 15,
        posts_read: 100,
        topics_created: 1,
        posts_created: 3,
        replies_created: 3,
        time_read_seconds: 3600,
        likes_given: 3,
        likes_received: 1,
        replies_received: 1
      },
      maximums: %{
        banned: 0,
        suspended: 0,
        posts_deleted: 0,
        suspensions_count: 0
      }
    },
    3 => %{
      minimums: %{
        account_age_days: 50,
        login_count: 10,
        days_visited: 50,
        topics_entered: 25,
        posts_read: 250,
        posts_created: 10,
        topics_created: 2,
        replies_created: 10,
        likes_given: 15,
        likes_received: 10,
        replies_received: 5
      },
      maximums: %{
        banned: 0,
        suspended: 0,
        flags_received: 3,
        posts_deleted: 1,
        suspensions_count: 0
      }
    }
    # TL4 is manual only
  }

  @incrementable_stats [
    :posts_created,
    :topics_created,
    :replies_created,
    :likes_given,
    :likes_received,
    :replies_received,
    :posts_read,
    :topics_entered,
    :time_read_seconds,
    :flags_given,
    :flags_received,
    :flags_agreed,
    :posts_deleted,
    :suspensions_count
  ]

  def levels, do: @levels
  def requirements, do: @requirements

  @doc """
  Get trust level name and info.
  """
  def get_level_info(level) when level in 0..4 do
    @levels[level]
  end

  def get_level_info(_), do: @levels[0]

  @doc """
  Check if user qualifies for a specific trust level.
  """
  def qualifies_for_level?(user, stats, target_level) when target_level in 1..3 do
    %{minimums: minimums, maximums: maximums} = @requirements[target_level]

    Enum.all?(minimums, fn {metric, required_value} ->
      metric_value(user, stats, metric) >= required_value
    end) and
      Enum.all?(maximums, fn {metric, allowed_value} ->
        metric_value(user, stats, metric) <= allowed_value
      end)
  end

  # TL0 is default
  def qualifies_for_level?(_, _, 0), do: true

  # TL4 is manual only
  def qualifies_for_level?(_, _, 4), do: false

  @doc """
  Calculate the maximum trust level a user qualifies for.
  """
  def calculate_trust_level(user, stats) do
    if user.trust_level_locked do
      user.trust_level
    else
      cond do
        qualifies_for_level?(user, stats, 3) -> 3
        qualifies_for_level?(user, stats, 2) -> 2
        qualifies_for_level?(user, stats, 1) -> 1
        true -> 0
      end
    end
  end

  @doc """
  Change a user's trust level and persist an audit log.
  """
  def change_user_level(user, new_level, opts \\ []) when new_level in 0..4 do
    persist_level_change(user, user.trust_level, new_level, opts, persist_user?: true)
  end

  @doc """
  Record a trust-level change after the caller has already updated `user.trust_level`.
  """
  def record_level_change(user, old_level, opts \\ []) when old_level in 0..4 do
    persist_level_change(user, old_level, user.trust_level, opts, persist_user?: false)
  end

  @doc """
  Backwards-compatible wrapper for older call sites.
  """
  def promote_user(
        user,
        new_level,
        reason \\ "automatic",
        changed_by_user_id \\ nil,
        notes \\ nil
      ) do
    change_user_level(user, new_level,
      reason: reason,
      changed_by_user_id: changed_by_user_id,
      notes: notes
    )
  end

  @doc """
  Automatically reconcile user trust levels based on their activity stats.
  Returns {:ok, changed_count} or {:error, reason}.
  """
  def auto_promote_eligible_users do
    users_with_stats =
      from(u in User,
        where: u.trust_level_locked == false,
        left_join: s in UserActivityStats,
        on: s.user_id == u.id,
        preload: [activity_stats: s]
      )
      |> Repo.all()

    changed_count =
      users_with_stats
      |> Enum.reduce(0, fn user, count ->
        stats = user.activity_stats || %UserActivityStats{}
        new_level = calculate_trust_level(user, stats)

        if new_level != user.trust_level do
          case change_user_level(user, new_level, reason: "automatic") do
            {:ok, _} -> count + 1
            {:error, _} -> count
          end
        else
          count
        end
      end)

    Logger.info("Auto-reconciled trust levels for #{changed_count} users")
    {:ok, changed_count}
  end

  @doc """
  Recalculate a single user's trust level and apply any automatic change immediately.
  """
  def maybe_auto_promote_user(user_id) do
    case get_user_with_stats(user_id) do
      nil ->
        {:error, :not_found}

      user ->
        stats = user.activity_stats || %UserActivityStats{}
        new_level = calculate_trust_level(user, stats)

        if new_level != user.trust_level do
          change_user_level(user, new_level, reason: "automatic")
        else
          {:ok, user}
        end
    end
  end

  @doc """
  Initialize activity stats for a user if they don't exist.
  """
  def ensure_activity_stats(user_id) do
    case Repo.get_by(UserActivityStats, user_id: user_id) do
      nil ->
        %UserActivityStats{user_id: user_id}
        |> UserActivityStats.changeset(%{})
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: :user_id
        )
        |> case do
          {:ok, %{id: nil}} ->
            {:ok, Repo.get_by!(UserActivityStats, user_id: user_id)}

          result ->
            result
        end

      stats ->
        {:ok, stats}
    end
  end

  @doc """
  Track a visit (daily).
  """
  def track_visit(user_id) do
    {:ok, _stats} = ensure_activity_stats(user_id)
    today = Date.utc_today()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {updated_count, _} =
      from(s in UserActivityStats,
        where:
          s.user_id == ^user_id and (is_nil(s.last_visit_date) or s.last_visit_date != ^today)
      )
      |> Repo.update_all(
        inc: [days_visited: 1],
        set: [last_visit_date: today, updated_at: now]
      )

    stats = Repo.get_by!(UserActivityStats, user_id: user_id)

    if updated_count > 0 do
      maybe_auto_promote_user(user_id)
    end

    {:ok, stats}
  end

  @doc """
  Increment a stat for a user.
  """
  def increment_stat(user_id, stat_name, amount \\ 1)

  def increment_stat(user_id, stat_name, amount)
      when stat_name in @incrementable_stats and is_integer(amount) do
    {:ok, _stats} = ensure_activity_stats(user_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in UserActivityStats, where: s.user_id == ^user_id)
    |> Repo.update_all(inc: [{stat_name, amount}], set: [updated_at: now])

    stats = Repo.get_by!(UserActivityStats, user_id: user_id)
    maybe_auto_promote_user(user_id)
    {:ok, stats}
  end

  def increment_stat(_user_id, stat_name, _amount), do: {:error, {:unknown_stat, stat_name}}

  defp persist_level_change(user, old_level, new_level, opts, persist_opts) do
    if new_level != old_level do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      reason = Keyword.get(opts, :reason, "automatic")
      changed_by_user_id = Keyword.get(opts, :changed_by_user_id)
      notes = Keyword.get(opts, :notes)
      persist_user? = Keyword.get(persist_opts, :persist_user?, true)

      user_changes =
        if persist_user? do
          %{trust_level: new_level, promoted_at: now}
        else
          %{promoted_at: now}
        end

      user_changeset = User.trust_level_changeset(user, user_changes)

      user_changeset =
        if new_level > old_level do
          Ecto.Changeset.change(user_changeset, %{
            email_sending_restricted: false,
            email_rate_limit_violations: 0,
            email_restriction_reason: nil,
            email_restricted_at: nil
          })
        else
          user_changeset
        end

      log_changeset =
        TrustLevelLog.changeset(%TrustLevelLog{}, %{
          user_id: user.id,
          old_level: old_level,
          new_level: new_level,
          reason: reason,
          changed_by_user_id: changed_by_user_id,
          notes: notes
        })

      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, user_changeset)
      |> Ecto.Multi.insert(:log, log_changeset)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: updated_user}} ->
          Logger.info(
            "User #{user.id} trust level changed from TL#{old_level} to TL#{new_level} (#{reason})"
          )

          if new_level > old_level do
            notify_promotion(user.id, old_level, new_level, reason)
          end

          {:ok, updated_user}

        {:error, _failed_operation, changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:ok, user}
    end
  end

  defp notify_promotion(user_id, old_level, new_level, reason) do
    Elektrine.Async.start(fn ->
      level_info = get_level_info(new_level)

      Elektrine.Notifications.create_notification(%{
        user_id: user_id,
        type: "trust_level_promoted",
        title: "Promoted to #{level_info.name}!",
        body:
          "Congratulations! You've been promoted to Trust Level #{new_level}: #{level_info.description}",
        metadata: %{
          "old_level" => old_level,
          "new_level" => new_level,
          "reason" => reason
        },
        priority: "high"
      })
    end)
  end

  defp get_user_with_stats(user_id) do
    from(u in User,
      where: u.id == ^user_id,
      left_join: s in UserActivityStats,
      on: s.user_id == u.id,
      preload: [activity_stats: s]
    )
    |> Repo.one()
  end

  defp metric_value(user, _stats, :account_age_days) do
    case user.inserted_at do
      %DateTime{} = inserted_at -> Date.diff(Date.utc_today(), DateTime.to_date(inserted_at))
      _ -> 0
    end
  end

  defp metric_value(user, _stats, :login_count), do: user.login_count || 0
  defp metric_value(user, _stats, :banned), do: if(user.banned, do: 1, else: 0)
  defp metric_value(user, _stats, :suspended), do: if(user.suspended, do: 1, else: 0)

  defp metric_value(_user, stats, metric) do
    Map.get(stats, metric, 0) || 0
  end
end
