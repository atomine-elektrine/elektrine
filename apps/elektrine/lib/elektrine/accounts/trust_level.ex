defmodule Elektrine.Accounts.TrustLevel do
  @moduledoc """
  Trust level system similar to Discourse.

  Trust Levels:
  - TL0 (New): Default for all new users
  - TL1 (Basic): Read and spent some time on the platform
  - TL2 (Member): Active participant
  - TL3 (Regular): Trusted community member with moderation powers
  - TL4 (Leader): Manually granted, full moderation access
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Accounts.{User, UserActivityStats, TrustLevelLog}
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

  # Trust level requirements (based on Discourse)
  @requirements %{
    1 => %{
      topics_entered: 5,
      posts_read: 30,
      # 10 minutes
      time_read_seconds: 600
    },
    2 => %{
      days_visited: 15,
      topics_created: 1,
      posts_created: 3,
      # 1 hour
      time_read_seconds: 3600,
      likes_given: 1,
      likes_received: 1,
      replies_received: 1
    },
    3 => %{
      days_visited: 50,
      posts_created: 10,
      topics_created: 2,
      likes_given: 30,
      likes_received: 20,
      replies_received: 5,
      # Must not abuse flagging
      flags_given: 0,
      # Must not be flagged
      flags_received: 0,
      # Must not have deleted posts
      posts_deleted: 0,
      # Must not be suspended
      suspensions_count: 0
    }
    # TL4 is manual only
  }

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
  def qualifies_for_level?(_user, stats, target_level) when target_level in 1..3 do
    requirements = @requirements[target_level]

    Enum.all?(requirements, fn {metric, required_value} ->
      actual_value = Map.get(stats, metric, 0)

      # For penalties, must be less than or equal (usually 0)
      if metric in [:flags_received, :posts_deleted, :suspensions_count] do
        actual_value <= required_value
      else
        actual_value >= required_value
      end
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
    # Skip if trust level is locked (manually set by admin)
    if user.trust_level_locked do
      user.trust_level
    else
      # Check from highest to lowest
      cond do
        qualifies_for_level?(user, stats, 3) -> 3
        qualifies_for_level?(user, stats, 2) -> 2
        qualifies_for_level?(user, stats, 1) -> 1
        true -> 0
      end
    end
  end

  @doc """
  Promote user to a new trust level.
  """
  def promote_user(
        user,
        new_level,
        reason \\ "automatic",
        changed_by_user_id \\ nil,
        notes \\ nil
      ) do
    old_level = user.trust_level

    if new_level != old_level do
      # Update user
      user_changeset =
        User.changeset(user, %{
          trust_level: new_level,
          promoted_at: DateTime.utc_now()
        })

      # Create log entry
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
            "User #{user.id} promoted from TL#{old_level} to TL#{new_level} (#{reason})"
          )

          # Send notification to user about promotion
          Task.start(fn ->
            level_info = get_level_info(new_level)

            # Create in-app notification
            Elektrine.Notifications.create_notification(%{
              user_id: user.id,
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

          {:ok, updated_user}

        {:error, _failed_operation, changeset, _changes} ->
          {:error, changeset}
      end
    else
      {:ok, user}
    end
  end

  @doc """
  Automatically promote users based on their activity stats.
  Returns {:ok, promoted_count} or {:error, reason}.
  """
  def auto_promote_eligible_users do
    # Get all users with their activity stats who aren't locked
    users_with_stats =
      from(u in User,
        where: u.trust_level_locked == false,
        left_join: s in UserActivityStats,
        on: s.user_id == u.id,
        preload: [activity_stats: s]
      )
      |> Repo.all()

    promoted_count =
      users_with_stats
      |> Enum.reduce(0, fn user, count ->
        stats = user.activity_stats || %UserActivityStats{}
        new_level = calculate_trust_level(user, stats)

        if new_level > user.trust_level do
          case promote_user(user, new_level, "automatic") do
            {:ok, _} -> count + 1
            {:error, _} -> count
          end
        else
          count
        end
      end)

    Logger.info("Auto-promoted #{promoted_count} users")
    {:ok, promoted_count}
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
            # Insert was skipped due to conflict, fetch the existing record
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
    {:ok, stats} = ensure_activity_stats(user_id)
    today = Date.utc_today()

    # Only increment if this is a new day
    if stats.last_visit_date != today do
      stats
      |> UserActivityStats.changeset(%{
        days_visited: stats.days_visited + 1,
        last_visit_date: today
      })
      |> Repo.update()
    else
      {:ok, stats}
    end
  end

  @doc """
  Increment a stat for a user.
  """
  def increment_stat(user_id, stat_name, amount \\ 1) do
    {:ok, stats} = ensure_activity_stats(user_id)

    current_value = Map.get(stats, stat_name, 0)

    stats
    |> UserActivityStats.changeset(%{stat_name => current_value + amount})
    |> Repo.update()
  end
end
