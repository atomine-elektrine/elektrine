defmodule ElektrineWeb.AdminController do
  @moduledoc """
  Admin dashboard controller. All other admin functions have been split into
  separate controllers under ElektrineWeb.Admin.* namespace.
  """

  use ElektrineWeb, :controller

  alias Elektrine.{Accounts, Email, Repo, Subscriptions}
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

  def dashboard(conn, _params) do
    invite_code_stats = Accounts.get_invite_code_stats()

    stats = %{
      total_users: get_user_count(),
      total_mailboxes: get_mailbox_count(),
      total_messages: get_message_count(),
      total_aliases: get_alias_count(),
      recent_users: get_recent_users(),
      pending_deletions: get_pending_deletion_count(),
      invite_codes_active: invite_code_stats.active,
      active_announcements: get_active_announcements_count(),
      two_factor_users: get_2fa_user_count(),
      imap_users: get_imap_user_count(),
      pop3_users: get_pop3_user_count(),
      email_storage: get_email_storage_stats(),
      active_users: get_active_user_stats(),
      pending_reports: Elektrine.Reports.count_pending_reports(),
      federation: get_federation_stats(),
      subscriptions: get_subscription_stats()
    }

    render(conn, :dashboard, stats: stats)
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
      COUNT(*) as total_messages,
      SUM(COALESCE(LENGTH(text_body), 0)) as text_size_bytes,
      SUM(COALESCE(LENGTH(html_body), 0)) as html_size_bytes,
      SUM(COALESCE(LENGTH(subject), 0)) as subject_size_bytes,
      AVG(COALESCE(LENGTH(text_body), 0)) as avg_text_size,
      MAX(COALESCE(LENGTH(text_body), 0)) as max_text_size,
      COUNT(CASE WHEN status = 'sent' THEN 1 END) as sent_messages,
      COUNT(CASE WHEN status = 'received' THEN 1 END) as received_messages,
      COUNT(CASE WHEN archived = true THEN 1 END) as archived_messages
    FROM email_messages
    """

    case Repo.query(storage_query) do
      {:ok,
       %{
         rows: [
           [
             total,
             text_bytes,
             html_bytes,
             subject_bytes,
             avg_text,
             max_text,
             sent,
             received,
             archived
           ]
         ]
       }} ->
        safe_total = if is_number(total), do: total, else: 0
        safe_text_bytes = if is_number(text_bytes), do: text_bytes, else: 0
        safe_html_bytes = if is_number(html_bytes), do: html_bytes, else: 0
        safe_subject_bytes = if is_number(subject_bytes), do: subject_bytes, else: 0
        safe_avg_text = if is_number(avg_text), do: avg_text, else: 0
        safe_max_text = if is_number(max_text), do: max_text, else: 0
        safe_sent = if is_number(sent), do: sent, else: 0
        safe_received = if is_number(received), do: received, else: 0
        safe_archived = if is_number(archived), do: archived, else: 0

        total_content_bytes = safe_text_bytes + safe_html_bytes + safe_subject_bytes

        %{
          total_messages: safe_total,
          total_content_mb: Float.round(total_content_bytes / 1_048_576, 2),
          avg_message_size_kb: Float.round(safe_avg_text / 1024, 1),
          largest_message_kb: Float.round(safe_max_text / 1024, 1),
          sent_messages: safe_sent,
          received_messages: safe_received,
          archived_messages: safe_archived
        }

      {:error, _} ->
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
end
