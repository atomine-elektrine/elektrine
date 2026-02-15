defmodule ElektrineWeb.Admin.MonitoringController do
  @moduledoc """
  Controller for admin monitoring functions including active users,
  IMAP/POP3 access tracking, and 2FA status management.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Repo}
  import Ecto.Query

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    timezone =
      if current_user && current_user.timezone, do: current_user.timezone, else: "Etc/UTC"

    time_format =
      if current_user && current_user.time_format, do: current_user.time_format, else: "12"

    conn
    |> assign(:timezone, timezone)
    |> assign(:time_format, time_format)
  end

  def active_users(conn, params) do
    page = SafeConvert.parse_page(params)
    timeframe = Map.get(params, "timeframe", "24h")
    per_page = 20
    offset = (page - 1) * per_page

    # Determine date range based on timeframe
    {cutoff_date, title} =
      case timeframe do
        "1h" -> {DateTime.add(DateTime.utc_now(), -1, :hour), "Last Hour"}
        "24h" -> {DateTime.add(DateTime.utc_now(), -1, :day), "Last 24 Hours"}
        "7d" -> {DateTime.add(DateTime.utc_now(), -7, :day), "Last 7 Days"}
        "30d" -> {DateTime.add(DateTime.utc_now(), -30, :day), "Last 30 Days"}
        "never" -> {nil, "Never Logged In"}
      end

    # Build query based on timeframe
    base_query =
      if timeframe == "never" do
        from(u in Accounts.User, where: is_nil(u.last_login_at))
      else
        from(u in Accounts.User, where: u.last_login_at >= ^cutoff_date)
      end

    # Get total count
    total_count = Repo.aggregate(base_query, :count)

    # Get paginated results
    active_users =
      base_query
      |> select([u], %{
        id: u.id,
        username: u.username,
        last_login_at: u.last_login_at,
        last_login_ip: u.last_login_ip,
        login_count: u.login_count,
        is_admin: u.is_admin,
        two_factor_enabled: u.two_factor_enabled,
        inserted_at: u.inserted_at
      })
      |> order_by([u], desc: u.last_login_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    total_pages = ceil(total_count / per_page)

    render(conn, :active_users,
      active_users: active_users,
      page: page,
      total_pages: total_pages,
      total_count: total_count,
      timeframe: timeframe,
      title: title,
      per_page: per_page
    )
  end

  def imap_users(conn, params) do
    page = SafeConvert.parse_page(params)
    per_page = 20
    offset = (page - 1) * per_page

    # Get total count
    total_count =
      Repo.aggregate(
        from(u in Accounts.User, where: not is_nil(u.last_imap_access)),
        :count
      )

    # Get paginated users
    users =
      from(u in Accounts.User,
        where: not is_nil(u.last_imap_access),
        select: %{
          id: u.id,
          username: u.username,
          last_imap_access: u.last_imap_access,
          last_login_at: u.last_login_at,
          is_admin: u.is_admin,
          banned: u.banned,
          avatar: u.avatar
        },
        order_by: [desc: u.last_imap_access],
        limit: ^per_page,
        offset: ^offset
      )
      |> Repo.all()

    total_pages = ceil(total_count / per_page)

    render(conn, :imap_users,
      users: users,
      page: page,
      total_pages: total_pages,
      total_count: total_count,
      per_page: per_page
    )
  end

  def pop3_users(conn, params) do
    page = SafeConvert.parse_page(params)
    per_page = 20
    offset = (page - 1) * per_page

    # Get total count
    total_count =
      Repo.aggregate(
        from(u in Accounts.User, where: not is_nil(u.last_pop3_access)),
        :count
      )

    # Get paginated users
    users =
      from(u in Accounts.User,
        where: not is_nil(u.last_pop3_access),
        select: %{
          id: u.id,
          username: u.username,
          last_pop3_access: u.last_pop3_access,
          last_login_at: u.last_login_at,
          is_admin: u.is_admin,
          banned: u.banned,
          avatar: u.avatar
        },
        order_by: [desc: u.last_pop3_access],
        limit: ^per_page,
        offset: ^offset
      )
      |> Repo.all()

    total_pages = ceil(total_count / per_page)

    render(conn, :pop3_users,
      users: users,
      page: page,
      total_pages: total_pages,
      total_count: total_count,
      per_page: per_page
    )
  end

  def two_factor_status(conn, params) do
    page = SafeConvert.parse_page(params)
    per_page = 20
    offset = (page - 1) * per_page

    # Get total count first
    total_2fa_users =
      from(u in Accounts.User, where: u.two_factor_enabled == true)
      |> Repo.aggregate(:count)

    # Get paginated users with 2FA enabled and their secret status
    two_factor_users =
      from(u in Accounts.User,
        where: u.two_factor_enabled == true,
        select: %{
          id: u.id,
          username: u.username,
          two_factor_enabled: u.two_factor_enabled,
          has_secret: not is_nil(u.two_factor_secret),
          secret_length: fragment("length(?)", u.two_factor_secret),
          backup_codes_count: fragment("array_length(?, 1)", u.two_factor_backup_codes),
          last_login_at: u.last_login_at
        },
        order_by: [desc: u.last_login_at],
        limit: ^per_page,
        offset: ^offset
      )
      |> Repo.all()

    # Get all 2FA users for stats (not paginated)
    all_2fa_users =
      from(u in Accounts.User,
        where: u.two_factor_enabled == true,
        select: %{
          has_secret: not is_nil(u.two_factor_secret)
        }
      )
      |> Repo.all()

    # Calculate pagination
    total_pages = ceil(total_2fa_users / per_page)
    page_range = pagination_range(page, total_pages)

    # Get total counts
    stats = %{
      total_2fa_users: total_2fa_users,
      users_with_secrets: Enum.count(all_2fa_users, & &1.has_secret),
      users_without_secrets: Enum.count(all_2fa_users, &(not &1.has_secret))
    }

    render(conn, :two_factor_status,
      users: two_factor_users,
      stats: stats,
      current_page: page,
      total_pages: total_pages,
      total_count: total_2fa_users,
      page_range: page_range
    )
  end

  @doc """
  Shows system health status including CPU, memory, and Oban queue stats.
  """
  def system_health(conn, _params) do
    scheduler_count = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:run_queue)
    cpu_stress = run_queue / scheduler_count

    # Memory stats
    memory = :erlang.memory()

    memory_mb = %{
      total: div(memory[:total], 1024 * 1024),
      processes: div(memory[:processes], 1024 * 1024),
      ets: div(memory[:ets], 1024 * 1024),
      binary: div(memory[:binary], 1024 * 1024)
    }

    # Oban queue stats
    oban_stats = get_oban_stats()

    # Domain throttler stats
    throttler_stats =
      try do
        Elektrine.ActivityPub.DomainThrottler.stats()
      rescue
        _ -> %{active_domains: 0, domains_in_backoff: 0, max_concurrent_per_domain: 2}
      end

    # DB pool stats
    db_stats = get_db_pool_stats()

    health = %{
      status: health_status(cpu_stress, oban_stats.available),
      cpu: %{
        schedulers: scheduler_count,
        run_queue: run_queue,
        stress: Float.round(cpu_stress, 2)
      },
      memory_mb: memory_mb,
      oban: oban_stats,
      throttler: throttler_stats,
      database: db_stats,
      uptime_seconds: div(:erlang.statistics(:wall_clock) |> elem(0), 1000)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(health))
  end

  defp health_status(cpu_stress, oban_available) do
    cond do
      cpu_stress > 3.0 -> "critical"
      cpu_stress > 2.0 -> "warning"
      oban_available > 500 -> "warning"
      oban_available > 1000 -> "critical"
      true -> "healthy"
    end
  end

  defp get_oban_stats do
    try do
      counts =
        Repo.all(
          from(j in "oban_jobs",
            group_by: j.state,
            select: {j.state, count(j.id)}
          ),
          timeout: 2000
        )
        |> Enum.into(%{})

      %{
        available: Map.get(counts, "available", 0),
        executing: Map.get(counts, "executing", 0),
        scheduled: Map.get(counts, "scheduled", 0),
        retryable: Map.get(counts, "retryable", 0),
        completed: Map.get(counts, "completed", 0),
        discarded: Map.get(counts, "discarded", 0)
      }
    rescue
      _ -> %{available: 0, executing: 0, scheduled: 0, retryable: 0, completed: 0, discarded: 0}
    end
  end

  defp get_db_pool_stats do
    # Get pool size from config
    pool_size = Application.get_env(:elektrine, Elektrine.Repo)[:pool_size] || 10
    %{pool_size: pool_size}
  end

  # Private helper functions

  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages//1 |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        1..7//1 |> Enum.to_list()

      current_page >= total_pages - 3 ->
        (total_pages - 6)..total_pages//1 |> Enum.to_list()

      true ->
        (current_page - 3)..(current_page + 3)//1 |> Enum.to_list()
    end
  end
end
