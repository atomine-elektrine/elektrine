defmodule Elektrine.Reports do
  @moduledoc """
  The Reports context for handling user reports across the platform.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Reports.Report

  @doc """
  Creates a report for any reportable entity with spam prevention.
  """
  def create_report(attrs \\ %{}) do
    with :ok <- validate_report_rate_limit(attrs[:reporter_id]),
         :ok <- validate_not_spam_reporting(attrs[:reporter_id]),
         {:ok, report} <- do_create_report(attrs) do
      {:ok, report}
    else
      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, :spam_detected} ->
        {:error, :spam_detected}

      error ->
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
    Report
    |> filter_by_status(filters[:status])
    |> filter_by_priority(filters[:priority])
    |> filter_by_reportable_type(filters[:reportable_type])
    |> filter_by_reporter(filters[:reporter_id])
    |> order_by([r], desc: r.inserted_at)
    |> preload([:reporter, :reviewed_by])
    |> Repo.all()
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

    report
    |> Report.review_changeset(attrs)
    |> Repo.update()
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
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 86400, :second)

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
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 86400, :second)

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
