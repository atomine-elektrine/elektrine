defmodule Elektrine.Reports do
  @moduledoc """
  The Reports context for handling user reports across the platform.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts
  alias Elektrine.Accounts.TrustLevel
  alias Elektrine.Accounts.User
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Notifications
  alias Elektrine.Repo
  alias Elektrine.Reports.Report
  alias Elektrine.Social.{Conversation, Message}
  alias Elektrine.Telemetry.Events

  @doc """
  Creates a report for any reportable entity with spam prevention.
  """
  def create_report(attrs \\ %{}) do
    reporter_id = report_attr(attrs, :reporter_id)

    with :ok <- validate_report_rate_limit(reporter_id),
         :ok <- validate_not_spam_reporting(reporter_id),
         {:ok, report} <- do_create_report(attrs) do
      maybe_record_report_creation(report)
      notify_admins_of_report(report)
      emit_report_event(:create, :success, report_metadata(report))
      {:ok, report}
    else
      {:error, :rate_limited} ->
        emit_report_event(:create, :failure, report_failure_metadata(attrs, :rate_limited))
        {:error, :rate_limited}

      {:error, :spam_detected} ->
        emit_report_event(:create, :failure, report_failure_metadata(attrs, :spam_detected))
        {:error, :spam_detected}

      {:error, %Ecto.Changeset{}} = error ->
        emit_report_event(:create, :failure, report_failure_metadata(attrs, :invalid))
        error

      error ->
        emit_report_event(:create, :failure, report_failure_metadata(attrs, :unknown))
        error
    end
  end

  defp do_create_report(attrs) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a single report.
  """
  def get_report!(id), do: Repo.get!(Report, id)

  @doc """
  Gets a report with associations preloaded.
  """
  def get_report_with_preloads!(id) do
    Report
    |> Repo.get!(id)
    |> Repo.preload([:reporter, :reviewed_by])
  end

  @doc """
  Lists all reports with optional filters.
  """
  def list_reports(filters \\ %{}) do
    filters
    |> reports_query()
    |> order_by([r], desc: r.inserted_at)
    |> preload([:reporter, :reviewed_by])
    |> Repo.all()
  end

  @doc """
  Returns a paginated slice of reports for admin surfaces.
  """
  def paginate_reports(filters \\ %{}, page \\ 1, per_page \\ 50) do
    page = normalize_page(page)
    per_page = normalize_per_page(per_page)
    query = reports_query(filters)
    total_count = Repo.aggregate(query, :count, :id)
    total_pages = total_pages(total_count, per_page)
    safe_page = min(page, total_pages)
    safe_offset = (safe_page - 1) * per_page

    entries =
      query
      |> order_by([r], desc: r.inserted_at)
      |> preload([:reporter, :reviewed_by])
      |> limit(^per_page)
      |> offset(^safe_offset)
      |> Repo.all()

    %{
      entries: entries,
      page: safe_page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages
    }
  end

  @doc """
  Lists pending reports count for admin dashboard.
  """
  def count_pending_reports do
    Report
    |> where([r], r.status == "pending")
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Counts reports matching optional filters without loading rows.
  """
  def count_reports(filters \\ %{}) do
    filters
    |> reports_query()
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns aggregate counts used by the admin reports dashboard.
  """
  def dashboard_stats do
    status_counts =
      Report
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.id)})
      |> Repo.all()
      |> Map.new()

    %{
      pending: Map.get(status_counts, "pending", 0),
      reviewing: Map.get(status_counts, "reviewing", 0),
      resolved: Map.get(status_counts, "resolved", 0),
      critical: count_reports(%{priority: "critical", status: "pending"})
    }
  end

  @doc """
  Checks if a user has already reported specific content.
  """
  def already_reported?(reporter_id, reportable_type, reportable_id) do
    Report
    |> where([r], r.reporter_id == ^reporter_id)
    |> where([r], r.reportable_type == ^reportable_type)
    |> where([r], r.reportable_id == ^reportable_id)
    |> where([r], r.status in ["pending", "reviewing"])
    |> Repo.exists?()
  end

  @doc """
  Updates a report's review status.
  """
  def review_report(%Report{} = report, attrs) do
    attrs = Map.put(attrs, :reviewed_at, DateTime.utc_now())

    report
    |> Report.review_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_report} = result ->
        maybe_record_report_resolution(report, updated_report)
        emit_report_event(:review, :success, report_review_metadata(report, updated_report))
        result

      {:error, %Ecto.Changeset{} = changeset} = error ->
        emit_report_event(
          :review,
          :failure,
          report_metadata(report)
          |> Map.merge(%{reason: :invalid, errors: length(changeset.errors)})
        )

        error

      error ->
        emit_report_event(
          :review,
          :failure,
          Map.merge(report_metadata(report), %{reason: :unknown})
        )

        error
    end
  end

  @doc """
  Updates a report's status with resolution notes.
  """
  def update_report_status(%Report{} = report, status, reviewer_id, resolution_notes \\ nil) do
    attrs = %{
      status: status,
      reviewed_by_id: reviewer_id,
      reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      resolution_notes: resolution_notes
    }

    review_report(report, attrs)
  end

  @doc """
  Resolves a report and applies the selected moderation action when it has a
  concrete side effect.
  """
  def resolve_report(%Report{} = report, %User{} = reviewer, attrs \\ %{}) do
    attrs =
      attrs
      |> atomize_review_attrs()
      |> Map.merge(%{status: "resolved", reviewed_by_id: reviewer.id})

    action = Map.get(attrs, :action_taken)

    case apply_resolution_action(report, reviewer, action) do
      :ok ->
        emit_report_event(
          :action,
          :success,
          report_metadata(report)
          |> Map.merge(%{action: normalize_report_action(action), reviewer_id: reviewer.id})
        )

        review_report(report, attrs)

      {:error, reason} = error ->
        emit_report_event(
          :action,
          :failure,
          report_metadata(report)
          |> Map.merge(%{
            action: normalize_report_action(action),
            reviewer_id: reviewer.id,
            reason: reason
          })
        )

        error
    end
  end

  @doc """
  Reopens a reviewed report and clears review metadata.
  """
  def reopen_report(%Report{} = report) do
    report
    |> Report.review_changeset(%{
      status: "pending",
      reviewed_by_id: nil,
      reviewed_at: nil,
      resolution_notes: nil,
      action_taken: nil
    })
    |> Repo.update()
    |> case do
      {:ok, updated_report} = result ->
        emit_report_event(:reopen, :success, report_review_metadata(report, updated_report))
        result

      {:error, %Ecto.Changeset{} = changeset} = error ->
        emit_report_event(
          :reopen,
          :failure,
          report_metadata(report)
          |> Map.merge(%{reason: :invalid, errors: length(changeset.errors)})
        )

        error
    end
  end

  @doc """
  Gets reports for a specific entity.
  """
  def get_reports_for(reportable_type, reportable_id) do
    Report
    |> where([r], r.reportable_type == ^reportable_type)
    |> where([r], r.reportable_id == ^reportable_id)
    |> preload([:reporter, :reviewed_by])
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets recent reports by a user.
  """
  def get_recent_reports_by_user(user_id, limit \\ 10) do
    Report
    |> where([r], r.reporter_id == ^user_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Counts reports by reason in a date range.
  """
  def count_reports_by_reason(from_date \\ nil, to_date \\ nil) do
    query = Report

    query =
      if from_date do
        where(query, [r], r.inserted_at >= ^from_date)
      else
        query
      end

    query =
      if to_date do
        where(query, [r], r.inserted_at <= ^to_date)
      else
        query
      end

    query
    |> group_by([r], r.reason)
    |> select([r], {r.reason, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  # Private helper functions

  defp reports_query(filters) do
    Report
    |> filter_by_status(filters[:status])
    |> filter_by_priority(filters[:priority])
    |> filter_by_reportable_type(filters[:reportable_type])
    |> filter_by_reporter(filters[:reporter_id])
  end

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status) do
    where(query, [r], r.status == ^status)
  end

  defp filter_by_priority(query, nil), do: query

  defp filter_by_priority(query, priority) do
    where(query, [r], r.priority == ^priority)
  end

  defp filter_by_reportable_type(query, nil), do: query

  defp filter_by_reportable_type(query, type) do
    where(query, [r], r.reportable_type == ^type)
  end

  defp filter_by_reporter(query, nil), do: query

  defp filter_by_reporter(query, reporter_id) do
    where(query, [r], r.reporter_id == ^reporter_id)
  end

  defp notify_admins_of_report(%Report{} = report) do
    admin_ids =
      User
      |> where([u], u.is_admin == true and u.banned == false and u.suspended == false)
      |> select([u], u.id)
      |> Repo.all()

    case admin_ids do
      [] ->
        :ok

      ids ->
        {:ok, _count} =
          Notifications.create_bulk_notifications(ids, %{
            type: "system",
            title: "New report",
            body: report_notification_body(report),
            url: "/pripyat/reports",
            icon: "hero-flag",
            priority: report_notification_priority(report.priority),
            actor_id: report.reporter_id,
            source_type: "report",
            source_id: report.id,
            metadata: %{
              "report_id" => report.id,
              "reportable_type" => report.reportable_type,
              "reportable_id" => report.reportable_id,
              "reason" => report.reason,
              "priority" => report.priority
            }
          })

        :ok
    end
  end

  defp report_notification_body(%Report{} = report) do
    "A #{report.reason || "policy"} report was filed for #{report.reportable_type || "content"} ##{report.reportable_id}."
  end

  defp report_notification_priority("critical"), do: "urgent"
  defp report_notification_priority("high"), do: "high"
  defp report_notification_priority(_), do: "normal"

  defp atomize_review_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {"status", value}, acc -> Map.put(acc, :status, value)
      {"priority", value}, acc -> Map.put(acc, :priority, value)
      {"reviewed_by_id", value}, acc -> Map.put(acc, :reviewed_by_id, value)
      {"reviewed_at", value}, acc -> Map.put(acc, :reviewed_at, value)
      {"resolution_notes", value}, acc -> Map.put(acc, :resolution_notes, value)
      {"action_taken", value}, acc -> Map.put(acc, :action_taken, value)
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {_key, _value}, acc -> acc
    end)
  end

  defp apply_resolution_action(_report, _reviewer, action)
       when action in [nil, "", "warned", "no_action"],
       do: :ok

  defp apply_resolution_action(%Report{} = report, %User{} = reviewer, "content_removed") do
    if report.reportable_type == "message" and is_integer(report.reportable_id) do
      case Messaging.admin_delete_message(report.reportable_id, reviewer) do
        {:ok, _message} -> :ok
        {:error, :already_deleted} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsupported_report_target}
    end
  end

  defp apply_resolution_action(%Report{} = report, _reviewer, "suspended") do
    with {:ok, user} <- report_target_user(report) do
      suspended_until = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      case Accounts.suspend_user(user, %{
             suspended_until: suspended_until,
             suspension_reason: "Suspended via report ##{report.id}"
           }) do
        {:ok, _user} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp apply_resolution_action(%Report{} = report, _reviewer, "banned") do
    with {:ok, user} <- report_target_user(report) do
      case Accounts.ban_user(user, %{banned_reason: "Banned via report ##{report.id}"}) do
        {:ok, _user} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp apply_resolution_action(_report, _reviewer, _action), do: {:error, :invalid_action}

  defp report_target_user(%Report{reportable_type: "user", reportable_id: user_id})
       when is_integer(user_id) and user_id > 0 do
    fetch_report_target_user(user_id)
  end

  defp report_target_user(%Report{reportable_type: "message", reportable_id: message_id})
       when is_integer(message_id) and message_id > 0 do
    case Repo.get(Message, message_id) || Repo.get(ChatMessage, message_id) do
      %{sender_id: sender_id} when is_integer(sender_id) -> fetch_report_target_user(sender_id)
      _message -> {:error, :target_user_not_found}
    end
  end

  defp report_target_user(%Report{} = report) do
    report.metadata
    |> metadata_value("account_id")
    |> parse_report_int()
    |> case do
      user_id when is_integer(user_id) and user_id > 0 -> fetch_report_target_user(user_id)
      _ -> {:error, :target_user_not_found}
    end
  end

  defp fetch_report_target_user(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :target_user_not_found}
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, metadata_atom_key(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp metadata_atom_key("account_id"), do: :account_id
  defp metadata_atom_key("status_ids"), do: :status_ids
  defp metadata_atom_key("forward"), do: :forward
  defp metadata_atom_key("rule_ids"), do: :rule_ids
  defp metadata_atom_key(_key), do: nil

  defp parse_report_int(value) when is_integer(value), do: value

  defp parse_report_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_report_int(_value), do: nil

  defp report_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp report_metadata(%Report{} = report) do
    %{
      report_id: report.id,
      reporter_id: report.reporter_id,
      reportable_type: report.reportable_type,
      reportable_id: report.reportable_id,
      reason: report.reason,
      priority: report.priority,
      status: report.status,
      action: normalize_report_action(report.action_taken)
    }
  end

  defp report_review_metadata(%Report{} = report, %Report{} = updated_report) do
    report_metadata(updated_report)
    |> Map.merge(%{
      previous_status: report.status,
      previous_action: normalize_report_action(report.action_taken),
      reviewer_id: updated_report.reviewed_by_id
    })
  end

  defp report_failure_metadata(attrs, reason) when is_map(attrs) do
    %{
      reporter_id: report_attr(attrs, :reporter_id),
      reportable_type: report_attr(attrs, :reportable_type),
      reportable_id: report_attr(attrs, :reportable_id),
      reason: reason
    }
  end

  defp normalize_report_action(action) when action in [nil, ""], do: :none
  defp normalize_report_action(action), do: action

  defp emit_report_event(operation, outcome, metadata) do
    Events.report(operation, outcome, metadata)
  end

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_page), do: 1

  defp normalize_per_page(per_page) when is_integer(per_page) and per_page > 0, do: per_page
  defp normalize_per_page(_per_page), do: 50

  defp total_pages(total_count, per_page) when total_count > 0 and per_page > 0 do
    div(total_count + per_page - 1, per_page)
  end

  defp total_pages(_, _), do: 1

  @doc """
  Builds metadata for different reportable types.
  """
  def build_metadata("user", user_id) do
    case Elektrine.Accounts.get_user!(user_id) do
      nil ->
        %{}

      user ->
        %{
          "username" => user.username,
          "display_name" => user.display_name
        }
    end
  rescue
    _ -> %{}
  end

  def build_metadata("message", message_id) do
    # Add logic to fetch message details when needed
    %{"message_id" => message_id}
  end

  def build_metadata("conversation", conversation_id) do
    # Add logic to fetch conversation details when needed
    %{"conversation_id" => conversation_id}
  end

  def build_metadata(_, _), do: %{}

  defp maybe_record_report_creation(%Report{} = report) do
    if local_reporter?(report) do
      TrustLevel.increment_stat(report.reporter_id, :flags_given)
    end

    report
    |> reported_user_ids()
    |> Enum.each(&TrustLevel.increment_stat(&1, :flags_received))
  end

  defp maybe_record_report_resolution(%Report{} = report, %Report{} = updated_report) do
    if local_reporter?(report) && actionable_transition?(report, updated_report) do
      TrustLevel.increment_stat(report.reporter_id, :flags_agreed)
    end
  end

  defp local_reporter?(%Report{metadata: metadata}) when is_map(metadata) do
    not Map.has_key?(metadata, "remote_reporter")
  end

  defp local_reporter?(_), do: true

  defp actionable_transition?(%Report{} = report, %Report{} = updated_report) do
    not actionable_action?(report.action_taken) and
      actionable_action?(updated_report.action_taken)
  end

  defp actionable_action?(action),
    do: action in ["warned", "suspended", "banned", "content_removed"]

  defp reported_user_ids(%Report{reportable_type: "user", reportable_id: user_id})
       when is_integer(user_id),
       do: [user_id]

  defp reported_user_ids(%Report{reportable_type: reportable_type, reportable_id: reportable_id})
       when reportable_type in ["message", "post"] do
    case Repo.get(Message, reportable_id) do
      %Message{sender_id: sender_id} when is_integer(sender_id) -> [sender_id]
      _ -> []
    end
  end

  defp reported_user_ids(%Report{reportable_type: "conversation", reportable_id: conversation_id}) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{creator_id: creator_id} when is_integer(creator_id) -> [creator_id]
      _ -> []
    end
  end

  defp reported_user_ids(_report), do: []

  # Spam Prevention Functions

  @doc """
  Rate limiting: Maximum 5 reports per hour per user
  """
  def validate_report_rate_limit(reporter_id) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    recent_reports_count =
      Report
      |> where([r], r.reporter_id == ^reporter_id)
      |> where([r], r.inserted_at > ^one_hour_ago)
      |> Repo.aggregate(:count, :id)

    if recent_reports_count >= 5 do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc """
  Check if user is spam reporting (too many dismissed reports)
  """
  def validate_not_spam_reporting(reporter_id) do
    # Check dismissed report ratio in last 30 days
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

    total_reports =
      Report
      |> where([r], r.reporter_id == ^reporter_id)
      |> where([r], r.inserted_at > ^thirty_days_ago)
      |> Repo.aggregate(:count, :id)

    dismissed_reports =
      Report
      |> where([r], r.reporter_id == ^reporter_id)
      |> where([r], r.inserted_at > ^thirty_days_ago)
      |> where([r], r.status == "dismissed")
      |> Repo.aggregate(:count, :id)

    # If more than 80% of reports are dismissed and user has made >10 reports, flag as spam
    if total_reports > 10 && dismissed_reports / total_reports > 0.8 do
      {:error, :spam_detected}
    else
      :ok
    end
  end

  @doc """
  Get time until user can report again (in seconds)
  """
  def get_report_cooldown(reporter_id) do
    last_report =
      Report
      |> where([r], r.reporter_id == ^reporter_id)
      |> order_by([r], desc: r.inserted_at)
      |> limit(1)
      |> Repo.one()

    case last_report do
      nil ->
        0

      report ->
        # 30 second cooldown between reports
        cooldown_seconds = 30
        elapsed = DateTime.diff(DateTime.utc_now(), report.inserted_at, :second)
        max(0, cooldown_seconds - elapsed)
    end
  end

  @doc """
  Check if user can submit a report (combines all spam checks)
  """
  def can_user_report?(reporter_id) do
    with :ok <- validate_report_rate_limit(reporter_id),
         :ok <- validate_not_spam_reporting(reporter_id),
         0 <- get_report_cooldown(reporter_id) do
      {:ok, true}
    else
      {:error, :rate_limited} ->
        {:error, "You have exceeded the report limit. Please try again later."}

      {:error, :spam_detected} ->
        {:error,
         "Your reporting privileges have been temporarily restricted due to excessive false reports."}

      cooldown when is_integer(cooldown) and cooldown > 0 ->
        {:error, "Please wait #{cooldown} seconds before submitting another report."}

      _ ->
        {:error, "Unable to submit report at this time."}
    end
  end

  @doc """
  Get user's reporting statistics
  """
  def get_user_report_stats(reporter_id) do
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

    reports =
      Report
      |> where([r], r.reporter_id == ^reporter_id)
      |> where([r], r.inserted_at > ^thirty_days_ago)
      |> Repo.all()

    %{
      total_reports: length(reports),
      pending: Enum.count(reports, &(&1.status == "pending")),
      resolved: Enum.count(reports, &(&1.status == "resolved")),
      dismissed: Enum.count(reports, &(&1.status == "dismissed")),
      reports_today:
        Enum.count(reports, fn r ->
          Date.compare(DateTime.to_date(r.inserted_at), Date.utc_today()) == :eq
        end)
    }
  end
end
