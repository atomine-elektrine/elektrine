defmodule ElektrineWeb.API.ReportController do
  @moduledoc """
  Report endpoints backed by Elektrine reports.
  """
  use ElektrineWeb, :controller

  alias Elektrine.{AuditLog, Reports}

  action_fallback ElektrineWeb.FallbackController

  def create(conn, params) do
    user = conn.assigns[:current_user]

    case Reports.create_report(report_attrs(user.id, params)) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(format_report(report))

      {:error, :rate_limited} ->
        too_many_requests(conn)

      {:error, :spam_detected} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "duplicate or spam report"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  def index(conn, params) do
    user = conn.assigns[:current_user]

    page =
      params
      |> report_filters(user)
      |> Reports.paginate_reports(
        parse_positive_int(params["page"], 1),
        parse_positive_int(params["per_page"] || params["limit"], 50)
      )

    conn
    |> put_resp_header("x-total-count", to_string(page.total_count))
    |> put_resp_header("x-page", to_string(page.page))
    |> put_resp_header("x-per-page", to_string(page.per_page))
    |> put_resp_header("x-total-pages", to_string(page.total_pages))
    |> json(Enum.map(page.entries, &format_report/1))
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Reports.get_report_with_preloads!(id) do
      report when user.is_admin or report.reporter_id == user.id ->
        json(conn, format_report(report))

      _report ->
        not_found(conn)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with :ok <- require_admin(conn),
         {:ok, report} <- fetch_report(id),
         {:ok, updated_report} <- Reports.review_report(report, moderation_attrs(params, user)) do
      audit_report_action(conn, user, report, updated_report, "report.update")
      json(conn, format_report(updated_report))
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, reason} when is_atom(reason) -> moderation_error(conn, reason)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def resolve(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with :ok <- require_admin(conn),
         {:ok, report} <- fetch_report(id),
         {:ok, updated_report} <-
           Reports.resolve_report(report, user, %{
             status: "resolved",
             reviewed_by_id: user.id,
             action_taken: normalize_action(params["action_taken"], "no_action"),
             resolution_notes: moderation_note(params)
           }) do
      audit_report_action(conn, user, report, updated_report, "report.resolve")
      json(conn, format_report(updated_report))
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, reason} when is_atom(reason) -> moderation_error(conn, reason)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def dismiss(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with :ok <- require_admin(conn),
         {:ok, report} <- fetch_report(id),
         {:ok, updated_report} <-
           Reports.review_report(report, %{
             status: "dismissed",
             reviewed_by_id: user.id,
             action_taken: normalize_action(params["action_taken"], "no_action"),
             resolution_notes: moderation_note(params)
           }) do
      audit_report_action(conn, user, report, updated_report, "report.dismiss")
      json(conn, format_report(updated_report))
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def reopen(conn, %{"id" => id}) do
    with :ok <- require_admin(conn),
         {:ok, report} <- fetch_report(id),
         {:ok, updated_report} <- Reports.reopen_report(report) do
      audit_report_action(
        conn,
        conn.assigns[:current_user],
        report,
        updated_report,
        "report.reopen"
      )

      json(conn, format_report(updated_report))
    else
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  defp report_attrs(reporter_id, params) do
    {reportable_type, reportable_id} = reportable(params)

    %{
      reporter_id: reporter_id,
      reportable_type: reportable_type,
      reportable_id: reportable_id,
      reason: normalize_reason(params["category"] || params["reason"]),
      description: params["comment"] || params["description"] || "",
      metadata: %{
        "account_id" => params["account_id"],
        "status_ids" => normalize_list(params["status_ids"]),
        "forward" => truthy?(params["forward"]),
        "rule_ids" => normalize_list(params["rule_ids"])
      }
    }
  end

  defp report_filters(params, %{is_admin: true}) do
    %{
      status: params["state"] || params["status"],
      priority: params["priority"],
      reportable_type: params["reportable_type"]
    }
  end

  defp report_filters(params, user) do
    %{
      reporter_id: user.id,
      status: params["state"] || params["status"]
    }
  end

  defp moderation_attrs(params, user) do
    %{
      status: blank_to_nil(params["status"]),
      priority: blank_to_nil(params["priority"]),
      action_taken: blank_to_nil(params["action_taken"]),
      resolution_notes: moderation_note(params),
      reviewed_by_id: user.id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp reportable(%{"status_ids" => status_ids}) do
    case normalize_list(status_ids) do
      [id | _] -> {"message", parse_int(id, 0)}
      [] -> {"user", 0}
    end
  end

  defp reportable(%{"account_id" => account_id}), do: {"user", parse_int(account_id, 0)}
  defp reportable(_params), do: {"user", 0}

  defp normalize_reason(reason) when reason in ["spam", "self_harm"], do: reason
  defp normalize_reason("violation"), do: "inappropriate"
  defp normalize_reason("legal"), do: "other"
  defp normalize_reason("harassment"), do: "harassment"
  defp normalize_reason("hate_speech"), do: "hate_speech"
  defp normalize_reason(_), do: "other"

  defp format_report(report) do
    %{
      id: to_string(report.id),
      action_taken: report.status in ["resolved", "dismissed"],
      action_taken_at: report.reviewed_at,
      action_taken_type: report.action_taken,
      category: report.reason,
      comment: report.description,
      forwarded: get_in(report.metadata || %{}, ["forward"]) == true,
      created_at: report.inserted_at,
      priority: report.priority,
      reportable_id: report.reportable_id,
      reportable_type: report.reportable_type,
      resolution_notes: report.resolution_notes,
      reviewed_by_id: maybe_to_string(report.reviewed_by_id),
      status: report.status,
      target_account_id: get_in(report.metadata || %{}, ["account_id"]),
      status_ids: get_in(report.metadata || %{}, ["status_ids"]) || []
    }
  end

  defp normalize_list(nil), do: []
  defp normalize_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_list(value) when is_binary(value), do: [value]
  defp normalize_list(_), do: []

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp fetch_report(id) do
    {:ok, Reports.get_report_with_preloads!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp require_admin(%{assigns: %{current_user: %{is_admin: true}}}), do: :ok
  defp require_admin(_conn), do: {:error, :forbidden}

  defp moderation_note(params) do
    params["resolution_notes"] || params["comment"] || params["note"]
  end

  defp normalize_action(nil, default), do: default
  defp normalize_action("", default), do: default
  defp normalize_action(action, _default), do: action

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp audit_report_action(conn, admin, report, updated_report, action) do
    AuditLog.log(admin.id, action, "report",
      target_user_id: report_target_user_id(report),
      resource_id: report.id,
      details: %{
        reporter_id: report.reporter_id,
        reportable_type: report.reportable_type,
        reportable_id: report.reportable_id,
        status_from: report.status,
        status_to: updated_report.status,
        priority_from: report.priority,
        priority_to: updated_report.priority,
        action_taken_from: report.action_taken,
        action_taken_to: updated_report.action_taken,
        reviewed_by_id: updated_report.reviewed_by_id
      },
      ip_address: ElektrineWeb.ClientIP.client_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    )
  end

  defp report_target_user_id(%{reportable_type: "user", reportable_id: user_id})
       when is_integer(user_id) and user_id > 0,
       do: user_id

  defp report_target_user_id(%{metadata: %{"account_id" => account_id}}),
    do: parse_int(account_id, nil)

  defp report_target_user_id(_report), do: nil

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_, default), do: default

  defp parse_positive_int(value, default) do
    case parse_int(value, default) do
      int when is_integer(int) and int > 0 -> int
      _ -> default
    end
  end

  defp too_many_requests(conn) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "rate limited"})
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
  end

  defp moderation_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason)})
  end
end
