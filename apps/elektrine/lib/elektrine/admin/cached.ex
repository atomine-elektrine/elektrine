defmodule Elektrine.Admin.Cached do
  @moduledoc """
  Cached admin dashboard functionality.
  Provides fast access to admin statistics and recent activity.
  """

  alias Elektrine.AppCache

  @doc """
  Gets cached total user count.
  """
  def get_user_count do
    {:ok, count} =
      AppCache.get_admin_stats(:user_count, fn ->
        count_users()
      end)

    count
  end

  @doc """
  Gets cached total mailbox count.
  """
  def get_mailbox_count do
    {:ok, count} =
      AppCache.get_admin_stats(:mailbox_count, fn ->
        count_mailboxes()
      end)

    count
  end

  @doc """
  Gets cached total message count.
  """
  def get_message_count do
    {:ok, count} =
      AppCache.get_admin_stats(:message_count, fn ->
        count_messages()
      end)

    count
  end

  @doc """
  Gets cached recent user registrations.
  """
  def get_recent_users(limit \\ 10) do
    {:ok, users} =
      AppCache.get_admin_recent_activity(:recent_users, fn ->
        get_recent_user_registrations(limit)
      end)

    users
  end

  @doc """
  Gets cached recent message activity.
  """
  def get_recent_messages(limit \\ 20) do
    {:ok, messages} =
      AppCache.get_admin_recent_activity(:recent_messages, fn ->
        get_recent_message_activity(limit)
      end)

    messages
  end

  @doc """
  Gets cached system health metrics.
  """
  def get_system_health do
    {:ok, health} =
      AppCache.get_admin_stats(:system_health, fn ->
        calculate_system_health()
      end)

    health
  end

  @doc """
  Gets cached email statistics.
  """
  def get_email_stats do
    {:ok, stats} =
      AppCache.get_admin_stats(:email_stats, fn ->
        calculate_email_statistics()
      end)

    stats
  end

  @doc """
  Gets cached invite code statistics.
  """
  def get_invite_stats do
    {:ok, stats} =
      AppCache.get_admin_stats(:invite_stats, fn ->
        calculate_invite_statistics()
      end)

    stats
  end

  @doc """
  Invalidates all admin caches.
  Should be called when admin-relevant data changes.
  """
  def invalidate_admin_caches do
    AppCache.invalidate_admin_cache()
  end

  @doc """
  Warms up admin dashboard cache.
  """
  def warm_admin_cache do
    # Side-effect (cache warmer): skip in tests.
    Elektrine.Async.start(fn ->
      # Preload all admin statistics
      get_user_count()
      get_mailbox_count()
      get_message_count()
      get_recent_users(10)
      get_recent_messages(20)
      get_system_health()
      get_email_stats()
      get_invite_stats()
    end)
  end

  # Private functions that implement the actual queries

  defp count_users do
    # This would query the database for total user count
    # Use live aggregate count until metrics snapshots are added.
    case Elektrine.Repo.aggregate(Elektrine.Accounts.User, :count) do
      count when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp count_mailboxes do
    # This would query the database for total mailbox count
    case Elektrine.Repo.aggregate(Elektrine.Email.Mailbox, :count) do
      count when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp count_messages do
    # This would query the database for total message count
    case Elektrine.Repo.aggregate(Elektrine.Email.Message, :count) do
      count when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp get_recent_user_registrations(limit) do
    # This would query for recent user registrations
    import Ecto.Query

    try do
      Elektrine.Accounts.User
      |> order_by([u], desc: u.inserted_at)
      |> limit(^limit)
      |> select([u], %{
        id: u.id,
        username: u.username,
        email: u.email,
        inserted_at: u.inserted_at
      })
      |> Elektrine.Repo.all()
    rescue
      _ -> []
    end
  end

  defp get_recent_message_activity(limit) do
    # This would query for recent message activity
    import Ecto.Query

    try do
      Elektrine.Email.Message
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)
      |> select([m], %{
        id: m.id,
        subject: m.subject,
        from: m.from,
        inserted_at: m.inserted_at,
        mailbox_id: m.mailbox_id
      })
      |> Elektrine.Repo.all()
    rescue
      _ -> []
    end
  end

  defp calculate_system_health do
    # Calculate various system health metrics
    try do
      %{
        database_status: check_database_connection(),
        cache_status: check_cache_status(),
        storage_usage: calculate_storage_usage(),
        uptime: get_system_uptime(),
        last_updated: DateTime.utc_now()
      }
    rescue
      _ ->
        %{
          database_status: :unknown,
          cache_status: :unknown,
          storage_usage: 0,
          uptime: 0,
          last_updated: DateTime.utc_now()
        }
    end
  end

  defp calculate_email_statistics do
    # Calculate email-related statistics
    import Ecto.Query

    try do
      today = Date.utc_today()
      week_ago = Date.add(today, -7)

      %{
        total_messages: count_messages(),
        messages_today: count_messages_since(today),
        messages_this_week: count_messages_since(week_ago),
        spam_rate: calculate_spam_rate(),
        average_per_day: calculate_average_messages_per_day()
      }
    rescue
      _ ->
        %{
          total_messages: 0,
          messages_today: 0,
          messages_this_week: 0,
          spam_rate: 0.0,
          average_per_day: 0.0
        }
    end
  end

  defp calculate_invite_statistics do
    # Calculate invite code statistics
    # This would query invite codes table if it exists
    %{
      total_invites: 0,
      used_invites: 0,
      pending_invites: 0,
      invite_rate: 0.0
    }
  end

  # Helper functions for system health

  defp check_database_connection do
    try do
      Elektrine.Repo.query("SELECT 1", [])
      :healthy
    rescue
      _ -> :unhealthy
    end
  end

  defp check_cache_status do
    try do
      AppCache.stats()
      :healthy
    rescue
      _ -> :unhealthy
    end
  end

  defp calculate_storage_usage do
    # This would calculate actual storage usage
    # Placeholder value until storage accounting is wired in.
    # 42MB
    42_000_000
  end

  defp get_system_uptime do
    # This would calculate actual system uptime
    # Placeholder value in seconds until uptime metrics are wired in.
    # 1 day
    86400
  end

  defp count_messages_since(date) do
    import Ecto.Query

    try do
      start_of_day = DateTime.new!(date, ~T[00:00:00])

      Elektrine.Email.Message
      |> where([m], m.inserted_at >= ^start_of_day)
      |> Elektrine.Repo.aggregate(:count)
    rescue
      _ -> 0
    end
  end

  defp calculate_spam_rate do
    # Calculate percentage of messages marked as spam
    try do
      total = count_messages()

      if total > 0 do
        spam_count =
          Elektrine.Email.Message
          |> Elektrine.Repo.aggregate(:count, :id, where: [spam: true])

        spam_count / total * 100
      else
        0.0
      end
    rescue
      _ -> 0.0
    end
  end

  defp calculate_average_messages_per_day do
    # Calculate average messages per day over last 30 days
    import Ecto.Query

    try do
      thirty_days_ago = Date.add(Date.utc_today(), -30)
      start_date = DateTime.new!(thirty_days_ago, ~T[00:00:00])

      count =
        from(m in Elektrine.Email.Message,
          where: m.inserted_at >= ^start_date,
          select: count(m.id)
        )
        |> Elektrine.Repo.one()

      (count || 0) / 30
    rescue
      _ -> 0.0
    end
  end
end
