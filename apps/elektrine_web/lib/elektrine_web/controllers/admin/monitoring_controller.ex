defmodule ElektrineWeb.Admin.MonitoringController do
  @moduledoc "Controller for admin monitoring functions including active users,\nIMAP/POP3 access tracking, and 2FA status management.\n"
  use ElektrineWeb, :controller
  alias Elektrine.{Accounts, Repo}
  alias ElektrineWeb.AdminSecurity
  import Ecto.Query
  plug(:put_layout, html: {ElektrineWeb.Layouts, :admin})
  plug(:assign_timezone_and_format)

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    timezone =
      if current_user && current_user.timezone do
        current_user.timezone
      else
        "Etc/UTC"
      end

    time_format =
      if current_user && current_user.time_format do
        current_user.time_format
      else
        "12"
      end

    conn |> assign(:timezone, timezone) |> assign(:time_format, time_format)
  end

  def active_users(conn, params) do
    page = SafeConvert.parse_page(params)
    timeframe = Map.get(params, "timeframe", "24h")
    per_page = 20
    safe_page = max(page, 1)
    offset = (safe_page - 1) * per_page
    now = DateTime.utc_now()
    epoch = ~U[1970-01-01 00:00:00Z]

    {cutoff_date, title} =
      case timeframe do
        "1h" -> {DateTime.add(now, -1, :hour), "Last Hour"}
        "24h" -> {DateTime.add(now, -1, :day), "Last 24 Hours"}
        "7d" -> {DateTime.add(now, -7, :day), "Last 7 Days"}
        "30d" -> {DateTime.add(now, -30, :day), "Last 30 Days"}
        "never" -> {nil, "Never Active"}
      end

    base_query =
      if timeframe == "never" do
        from(u in Accounts.User,
          where:
            is_nil(u.last_login_at) and is_nil(u.last_imap_access) and is_nil(u.last_pop3_access)
        )
      else
        from(u in Accounts.User,
          where:
            u.last_login_at >= ^cutoff_date or
              u.last_imap_access >= ^cutoff_date or
              u.last_pop3_access >= ^cutoff_date
        )
      end

    total_count = Repo.aggregate(base_query, :count)

    active_users =
      base_query
      |> select([u], %{
        id: u.id,
        username: u.username,
        last_login_at: u.last_login_at,
        last_imap_access: u.last_imap_access,
        last_pop3_access: u.last_pop3_access,
        last_login_ip: u.last_login_ip,
        login_count: u.login_count,
        is_admin: u.is_admin,
        two_factor_enabled: u.two_factor_enabled,
        inserted_at: u.inserted_at,
        last_activity_at:
          fragment(
            "GREATEST(COALESCE(?, ?), COALESCE(?, ?), COALESCE(?, ?))",
            u.last_login_at,
            type(^epoch, :utc_datetime),
            u.last_imap_access,
            type(^epoch, :utc_datetime),
            u.last_pop3_access,
            type(^epoch, :utc_datetime)
          )
      })
      |> order_by(
        [u],
        desc:
          fragment(
            "GREATEST(COALESCE(?, ?), COALESCE(?, ?), COALESCE(?, ?))",
            u.last_login_at,
            type(^epoch, :utc_datetime),
            u.last_imap_access,
            type(^epoch, :utc_datetime),
            u.last_pop3_access,
            type(^epoch, :utc_datetime)
          )
      )
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> Enum.map(&add_activity_metadata/1)

    total_pages = ceil(total_count / per_page)

    render(conn, :active_users,
      active_users: active_users,
      page: safe_page,
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

    total_count =
      Repo.aggregate(
        from(u in Accounts.User, where: not is_nil(u.last_imap_access)),
        :count
      )

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

    total_count =
      Repo.aggregate(
        from(u in Accounts.User, where: not is_nil(u.last_pop3_access)),
        :count
      )

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

    total_2fa_users =
      from(u in Accounts.User, where: u.two_factor_enabled == true) |> Repo.aggregate(:count)

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

    users_with_secrets =
      from(u in Accounts.User,
        where: u.two_factor_enabled == true and not is_nil(u.two_factor_secret)
      )
      |> Repo.aggregate(:count)

    total_pages = ceil(total_2fa_users / per_page)
    page_range = pagination_range(page, total_pages)

    stats = %{
      total_2fa_users: total_2fa_users,
      users_with_secrets: users_with_secrets,
      users_without_secrets: max(total_2fa_users - users_with_secrets, 0)
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

  def operations(conn, _params) do
    snapshot = operational_snapshot()

    render(conn, :operations,
      health: snapshot.health,
      live: snapshot.live,
      oban: snapshot.oban,
      queue_pressure: snapshot.queue_pressure,
      load_guard: snapshot.load_guard,
      throttler: snapshot.throttler,
      database: snapshot.database,
      media_proxy_cache: Elektrine.MediaProxy.cache_state(25),
      media_proxy_purge_grant:
        AdminSecurity.issue_action_grant(
          conn,
          conn.assigns.current_user,
          "POST",
          "/pripyat/media-proxy-cache/purge"
        ),
      media_proxy_unban_grant:
        AdminSecurity.issue_action_grant(
          conn,
          conn.assigns.current_user,
          "POST",
          "/pripyat/media-proxy-cache/unban"
        )
    )
  end

  @doc "Shows system health status including CPU, memory, and Oban queue stats.\n"
  def system_health(conn, _params) do
    snapshot = operational_snapshot()

    health =
      snapshot.health
      |> Map.merge(%{
        oban: snapshot.oban,
        operational: %{
          live: snapshot.live,
          queue_pressure: snapshot.queue_pressure,
          load_guard: snapshot.load_guard
        },
        throttler: snapshot.throttler,
        database: snapshot.database
      })

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(health))
  end

  defp operational_snapshot do
    scheduler_count = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:run_queue)
    cpu_stress = run_queue / scheduler_count
    memory = :erlang.memory()

    memory_mb = %{
      total: div(memory[:total], 1024 * 1024),
      processes: div(memory[:processes], 1024 * 1024),
      ets: div(memory[:ets], 1024 * 1024),
      binary: div(memory[:binary], 1024 * 1024)
    }

    oban_stats = get_oban_stats()
    queue_pressure = get_oban_queue_pressure()
    load_guard = get_load_guard_stats(queue_pressure)

    throttler_stats =
      try do
        Elektrine.ActivityPub.DomainThrottler.stats()
      rescue
        _ -> %{active_domains: 0, domains_in_backoff: 0, max_concurrent_per_domain: 2}
      end

    db_stats = get_db_pool_stats()
    live_stats = Elektrine.JobQueueMonitor.stats()

    health = %{
      status: health_status(cpu_stress, oban_stats.available, load_guard.overloaded),
      cpu: %{
        schedulers: scheduler_count,
        run_queue: run_queue,
        stress: Float.round(cpu_stress, 2)
      },
      memory_mb: memory_mb,
      uptime_seconds: div(:erlang.statistics(:wall_clock) |> elem(0), 1000)
    }

    %{
      health: health,
      live: live_stats,
      oban: oban_stats,
      queue_pressure: queue_pressure,
      load_guard: load_guard,
      throttler: throttler_stats,
      database: db_stats
    }
  end

  def job_queue_stats(conn, _params) do
    queue_pressure = get_oban_queue_pressure()

    payload = %{
      live: Elektrine.JobQueueMonitor.stats(),
      database: get_oban_stats(),
      queue_pressure: queue_pressure,
      load_guard: get_load_guard_stats(queue_pressure)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  def media_proxy_cache(conn, params) do
    limit =
      params
      |> Map.get("limit", "100")
      |> SafeConvert.to_integer(100)
      |> max(1)
      |> min(500)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Elektrine.MediaProxy.cache_state(limit)))
  end

  def purge_media_proxy_cache(conn, params) do
    result = Elektrine.MediaProxy.purge(media_proxy_urls(params), ban: truthy?(params["ban"]))

    media_proxy_response(conn, result, "Media proxy cache updated.")
  end

  def unban_media_proxy_cache(conn, params) do
    result =
      params
      |> media_proxy_urls()
      |> Enum.map(fn url ->
        case Elektrine.MediaProxy.unban(url) do
          {:ok, _} -> {:unbanned, url}
          _ -> {:rejected, url}
        end
      end)
      |> Enum.reduce(%{unbanned: [], rejected: []}, fn
        {:unbanned, url}, acc -> update_in(acc.unbanned, &[url | &1])
        {:rejected, url}, acc -> update_in(acc.rejected, &[url | &1])
      end)
      |> Map.update!(:unbanned, &Enum.reverse/1)
      |> Map.update!(:rejected, &Enum.reverse/1)

    media_proxy_response(conn, result, "Media proxy bans updated.")
  end

  defp health_status(cpu_stress, oban_available, load_guard_overloaded) do
    cond do
      load_guard_overloaded -> "critical"
      cpu_stress > 3.0 -> "critical"
      oban_available > 1000 -> "critical"
      cpu_stress > 2.0 -> "warning"
      oban_available > 500 -> "warning"
      true -> "healthy"
    end
  end

  defp get_oban_stats do
    active_states = ["available", "executing", "scheduled", "retryable"]

    counts =
      Repo.all(
        from(j in "oban_jobs",
          where: j.state in ^active_states,
          group_by: j.state,
          select: {j.state, count(j.id)}
        ),
        timeout: 750,
        pool_timeout: 200
      )
      |> Enum.into(%{})

    %{
      available: Map.get(counts, "available", 0),
      executing: Map.get(counts, "executing", 0),
      scheduled: Map.get(counts, "scheduled", 0),
      retryable: Map.get(counts, "retryable", 0),
      completed: 0,
      discarded: 0
    }
  rescue
    _ -> %{available: 0, executing: 0, scheduled: 0, retryable: 0, completed: 0, discarded: 0}
  end

  defp media_proxy_urls(params) do
    params
    |> Map.get("urls", Map.get(params, "url", []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp media_proxy_response(conn, result, html_message) do
    if html_request?(conn) do
      conn
      |> put_flash(:info, html_message)
      |> redirect(to: ~p"/pripyat/operations")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(result))
    end
  end

  defp html_request?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp get_db_pool_stats do
    pool_size = Application.get_env(:elektrine, Elektrine.Repo)[:pool_size] || 10
    %{pool_size: pool_size}
  end

  defp get_oban_queue_pressure do
    active_states = ["available", "executing", "scheduled", "retryable"]

    Repo.all(
      from(j in "oban_jobs",
        where: j.state in ^active_states,
        group_by: [j.queue, j.state],
        select: {j.queue, j.state, count(j.id)}
      ),
      timeout: 750,
      pool_timeout: 200
    )
    |> Enum.reduce(%{}, fn {queue, state, count}, acc ->
      queue = queue || "unknown"
      state = state || "unknown"

      acc
      |> Map.put_new(queue, empty_queue_pressure())
      |> update_in([queue, state], &((&1 || 0) + count))
      |> update_in([queue, "total"], &((&1 || 0) + count))
    end)
  rescue
    _ -> %{}
  end

  defp empty_queue_pressure do
    %{
      "available" => 0,
      "executing" => 0,
      "scheduled" => 0,
      "retryable" => 0,
      "total" => 0
    }
  end

  defp get_load_guard_stats(queue_pressure) do
    config = Application.get_env(:elektrine, :federation_load_guard, [])
    threshold = Keyword.get(config, :max_available_or_retryable, 50_000)
    enabled = Keyword.get(config, :enabled, true)
    federation = Map.get(queue_pressure, "federation", empty_queue_pressure())
    depth = Map.get(federation, "available", 0) + Map.get(federation, "retryable", 0)

    %{
      enabled: enabled,
      max_available_or_retryable: threshold,
      available_or_retryable: depth,
      overloaded: enabled and depth >= threshold
    }
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_), do: false

  defp add_activity_metadata(user) do
    activities =
      [
        {:web, user.last_login_at},
        {:imap, user.last_imap_access},
        {:pop3, user.last_pop3_access}
      ]
      |> Enum.filter(fn {_source, timestamp} -> not is_nil(timestamp) end)

    case Enum.max_by(activities, fn {_source, timestamp} -> timestamp end, fn -> nil end) do
      {source, timestamp} ->
        user
        |> Map.put(:last_activity_at, timestamp)
        |> Map.put(:last_activity_source, source)

      nil ->
        user
        |> Map.put(:last_activity_at, nil)
        |> Map.put(:last_activity_source, nil)
    end
  end

  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    1..total_pages//1 |> Enum.to_list()
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 -> 1..7//1 |> Enum.to_list()
      current_page >= total_pages - 3 -> (total_pages - 6)..total_pages//1 |> Enum.to_list()
      true -> (current_page - 3)..(current_page + 3)//1 |> Enum.to_list()
    end
  end
end
