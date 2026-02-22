defmodule ElektrineWeb.AdminController do
  @moduledoc """
  Admin dashboard controller. All other admin functions have been split into
  separate controllers under ElektrineWeb.Admin.* namespace.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, AppCache, Email, Repo, Subscriptions}
  import Ecto.Query

  @dashboard_stat_timeout_ms 4_000
  @dashboard_max_concurrency 6

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

  def dashboard(conn, params) do
    if truthy_param?(Map.get(params, "refresh")) do
      AppCache.invalidate_admin_cache()
    end

    stats =
      AppCache.get_admin_stats(:dashboard_overview, fn ->
        build_dashboard_stats()
      end)
      |> case do
        {:ok, value} -> value
        _ -> build_dashboard_stats()
      end

    refresh_enabled = Map.get(params, "refresh") == "1"

    render(conn, :dashboard, stats: stats, refresh_enabled: refresh_enabled)
  end

  defp build_dashboard_stats do
    invite_code_stats =
      safe_dashboard_call(fn -> Accounts.get_invite_code_stats() end, %{active: 0})

    async_stats =
      [
        {:total_users, fn -> get_user_count() end, 0},
        {:total_mailboxes, fn -> get_mailbox_count() end, 0},
        {:total_messages, fn -> get_message_count() end, 0},
        {:total_aliases, fn -> get_alias_count() end, 0},
        {:recent_users, fn -> get_recent_users() end, []},
        {:pending_deletions, fn -> get_pending_deletion_count() end, 0},
        {:active_announcements, fn -> get_active_announcements_count() end, 0},
        {:two_factor_users, fn -> get_2fa_user_count() end, 0},
        {:imap_users, fn -> get_imap_user_count() end, 0},
        {:pop3_users, fn -> get_pop3_user_count() end, 0},
        {:email_storage, fn -> get_email_storage_stats() end, default_email_storage_stats()},
        {:active_users, fn -> get_active_user_stats() end, default_active_user_stats()},
        {:pending_reports, fn -> Elektrine.Reports.count_pending_reports() end, 0},
        {:federation, fn -> get_federation_stats() end, default_federation_stats()},
        {:subscriptions, fn -> get_subscription_stats() end, default_subscription_stats()}
      ]
      |> Task.async_stream(
        fn {key, fetch_fn, fallback} ->
          {key, safe_dashboard_call(fetch_fn, fallback)}
        end,
        ordered: false,
        timeout: @dashboard_stat_timeout_ms,
        on_timeout: :kill_task,
        max_concurrency: @dashboard_max_concurrency
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, value}}, acc ->
          Map.put(acc, key, value)

        {:exit, _reason}, acc ->
          acc
      end)

    %{
      total_users: Map.get(async_stats, :total_users, 0),
      total_mailboxes: Map.get(async_stats, :total_mailboxes, 0),
      total_messages: Map.get(async_stats, :total_messages, 0),
      total_aliases: Map.get(async_stats, :total_aliases, 0),
      recent_users: Map.get(async_stats, :recent_users, []),
      pending_deletions: Map.get(async_stats, :pending_deletions, 0),
      invite_codes_active: Map.get(invite_code_stats, :active, 0),
      active_announcements: Map.get(async_stats, :active_announcements, 0),
      two_factor_users: Map.get(async_stats, :two_factor_users, 0),
      imap_users: Map.get(async_stats, :imap_users, 0),
      pop3_users: Map.get(async_stats, :pop3_users, 0),
      email_storage: Map.get(async_stats, :email_storage, default_email_storage_stats()),
      active_users: Map.get(async_stats, :active_users, default_active_user_stats()),
      pending_reports: Map.get(async_stats, :pending_reports, 0),
      federation: Map.get(async_stats, :federation, default_federation_stats()),
      subscriptions: Map.get(async_stats, :subscriptions, default_subscription_stats())
    }
  end

  # Helper functions for dashboard stats

  defp get_user_count do
    Repo.aggregate(Accounts.User, :count, :id)
  end

  defp get_mailbox_count do
    Repo.aggregate(Email.Mailbox, :count, :id)
  end

  defp get_message_count do
    Repo.aggregate(Email.Message, :count, :id)
  end

  defp get_alias_count do
    Repo.aggregate(Email.Alias, :count, :id)
  end

  defp get_active_announcements_count do
    Repo.aggregate(
      from(a in Elektrine.Admin.Announcement, where: a.active == true),
      :count,
      :id
    )
  end

  defp get_2fa_user_count do
    Repo.aggregate(
      from(u in Accounts.User, where: u.two_factor_enabled == true),
      :count,
      :id
    )
  end

  defp get_imap_user_count do
    Repo.aggregate(
      from(u in Accounts.User, where: not is_nil(u.last_imap_access)),
      :count,
      :id
    )
  end

  defp get_pop3_user_count do
    Repo.aggregate(
      from(u in Accounts.User, where: not is_nil(u.last_pop3_access)),
      :count,
      :id
    )
  end

  defp get_active_user_stats do
    now = DateTime.utc_now()
    one_day_ago = DateTime.add(now, -1, :day)
    one_week_ago = DateTime.add(now, -7, :day)
    one_month_ago = DateTime.add(now, -30, :day)

    # Count users active via web login OR IMAP/POP3 access
    %{
      last_24_hours:
        Repo.aggregate(
          from(u in Accounts.User,
            where:
              u.last_login_at >= ^one_day_ago or
                u.last_imap_access >= ^one_day_ago or
                u.last_pop3_access >= ^one_day_ago
          ),
          :count,
          :id
        ),
      last_7_days:
        Repo.aggregate(
          from(u in Accounts.User,
            where:
              u.last_login_at >= ^one_week_ago or
                u.last_imap_access >= ^one_week_ago or
                u.last_pop3_access >= ^one_week_ago
          ),
          :count,
          :id
        ),
      last_30_days:
        Repo.aggregate(
          from(u in Accounts.User,
            where:
              u.last_login_at >= ^one_month_ago or
                u.last_imap_access >= ^one_month_ago or
                u.last_pop3_access >= ^one_month_ago
          ),
          :count,
          :id
        ),
      never_logged_in:
        Repo.aggregate(
          from(u in Accounts.User,
            where:
              is_nil(u.last_login_at) and
                is_nil(u.last_imap_access) and
                is_nil(u.last_pop3_access)
          ),
          :count,
          :id
        )
    }
  end

  defp get_email_storage_stats do
    storage_query = """
    SELECT
      COALESCE(
        (
          SELECT n_live_tup::bigint
          FROM pg_stat_user_tables
          WHERE schemaname = current_schema() AND relname = 'email_messages'
        ),
        0
      ) as estimated_messages,
      COALESCE(pg_total_relation_size('email_messages'), 0) as total_storage_bytes
    """

    case Repo.query(storage_query, [], timeout: 1_500) do
      {:ok, %{rows: [[estimated_messages, total_storage_bytes]]}} ->
        safe_total = normalize_stat_number(estimated_messages)
        safe_total_bytes = normalize_stat_number(total_storage_bytes)
        avg_size_bytes = if safe_total > 0, do: safe_total_bytes / safe_total, else: 0

        %{
          total_messages: safe_total,
          total_content_mb: Float.round(safe_total_bytes / 1_048_576, 2),
          avg_message_size_kb: Float.round(avg_size_bytes / 1024, 1),
          largest_message_kb: 0.0,
          sent_messages: 0,
          received_messages: 0,
          archived_messages: 0
        }

      _ ->
        default_email_storage_stats()
    end
  end

  defp get_recent_users do
    from(u in Accounts.User,
      order_by: [desc: u.inserted_at],
      limit: 10,
      select: [:id, :username, :is_admin, :banned, :inserted_at]
    )
    |> Repo.all()
  end

  defp get_pending_deletion_count do
    from(r in Elektrine.Accounts.AccountDeletionRequest,
      where: r.status == "pending"
    )
    |> Repo.aggregate(:count)
  end

  defp get_federation_stats do
    alias Elektrine.ActivityPub.{Actor, Instance, RelaySubscription}

    %{
      remote_actors: Repo.aggregate(Actor, :count, :id),
      unique_domains:
        Repo.aggregate(
          from(a in Actor, select: a.domain, distinct: true),
          :count
        ),
      blocked_instances:
        Repo.aggregate(
          from(i in Instance, where: i.blocked == true),
          :count,
          :id
        ),
      active_relays:
        Repo.aggregate(
          from(r in RelaySubscription, where: r.status == "active" and r.accepted == true),
          :count,
          :id
        ),
      pending_relays:
        Repo.aggregate(
          from(r in RelaySubscription, where: r.status == "pending"),
          :count,
          :id
        )
    }
  end

  defp get_subscription_stats do
    alias Subscriptions.Subscription

    products = Subscriptions.list_products()
    active_products = Enum.count(products, & &1.active)

    active_subscriptions =
      Repo.aggregate(
        from(s in Subscription, where: s.status in ["active", "trialing"]),
        :count,
        :id
      )

    total_subscriptions = Repo.aggregate(Subscription, :count, :id)

    %{
      total_products: length(products),
      active_products: active_products,
      active_subscriptions: active_subscriptions,
      total_subscriptions: total_subscriptions
    }
  end

  defp safe_dashboard_call(fetch_fn, fallback) when is_function(fetch_fn, 0) do
    fetch_fn.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end

  defp normalize_stat_number(value) when is_integer(value) and value >= 0, do: value
  defp normalize_stat_number(value) when is_float(value) and value >= 0, do: trunc(value)
  defp normalize_stat_number(_), do: 0

  defp default_active_user_stats do
    %{
      last_24_hours: 0,
      last_7_days: 0,
      last_30_days: 0,
      never_logged_in: 0
    }
  end

  defp default_email_storage_stats do
    %{
      total_messages: 0,
      total_content_mb: 0.0,
      avg_message_size_kb: 0.0,
      largest_message_kb: 0.0,
      sent_messages: 0,
      received_messages: 0,
      archived_messages: 0
    }
  end

  defp default_federation_stats do
    %{
      remote_actors: 0,
      unique_domains: 0,
      blocked_instances: 0,
      active_relays: 0,
      pending_relays: 0
    }
  end

  defp default_subscription_stats do
    %{
      total_products: 0,
      active_products: 0,
      active_subscriptions: 0,
      total_subscriptions: 0
    }
  end

  defp truthy_param?(value) when value in [true, 1, "1", "true", "on", "yes"], do: true
  defp truthy_param?(_), do: false
end
