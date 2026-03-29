defmodule ElektrineWeb.Admin.DeletionRequestsController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts

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

  def index(conn, _params) do
    requests = Accounts.list_deletion_requests()
    render(conn, :deletion_requests, requests: requests)
  end

  def show(conn, %{"id" => id}) do
    case Accounts.get_deletion_request!(id) do
      nil ->
        conn
        |> put_flash(:error, "Deletion request not found")
        |> redirect(to: ~p"/pripyat/deletion-requests")

      request ->
        render(conn, :show_deletion_request, request: request)
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_flash(:error, "Deletion request not found")
      |> redirect(to: ~p"/pripyat/deletion-requests")
  end

  def approve(conn, %{"id" => id, "admin_notes" => admin_notes}) do
    request = Accounts.get_deletion_request!(id)
    admin = conn.assigns.current_user

    case Accounts.review_deletion_request(request, admin, "approved", %{admin_notes: admin_notes}) do
      {:ok, _updated_request} ->
        Elektrine.AuditLog.log(
          admin.id,
          "approve",
          "deletion_request",
          details: %{
            request_id: request.id,
            deleted_user_id: request.user_id,
            deleted_username: request.user.username,
            admin_notes: admin_notes,
            requested_at: request.inserted_at
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "Account deletion request approved and user account deleted.")
        |> redirect(to: ~p"/pripyat/deletion-requests")

      {:error, error} when is_binary(error) ->
        conn
        |> put_flash(:error, error)
        |> redirect(to: ~p"/pripyat/deletion-requests/#{id}")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to approve deletion request.")
        |> redirect(to: ~p"/pripyat/deletion-requests/#{id}")
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_flash(:error, "Deletion request not found")
      |> redirect(to: ~p"/pripyat/deletion-requests")
  end

  def approve(conn, %{"id" => id}) do
    approve(conn, %{"id" => id, "admin_notes" => ""})
  end

  def bulk_approve(conn, params) do
    admin = conn.assigns.current_user
    admin_notes = Map.get(params, "admin_notes", "")

    request_ids =
      params
      |> Map.get("request_ids", [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case request_ids do
      [] ->
        conn
        |> put_flash(:error, "Select at least one pending request to approve.")
        |> redirect(to: ~p"/pripyat/deletion-requests")

      _ ->
        {approved_count, skipped_count} =
          approve_selected_requests(request_ids, admin, admin_notes, conn)

        conn
        |> put_flash(
          flash_kind(approved_count),
          bulk_approval_message(approved_count, skipped_count)
        )
        |> redirect(to: ~p"/pripyat/deletion-requests")
    end
  end

  def deny(conn, %{"id" => id, "admin_notes" => admin_notes}) do
    request = Accounts.get_deletion_request!(id)
    admin = conn.assigns.current_user

    case Accounts.review_deletion_request(request, admin, "denied", %{admin_notes: admin_notes}) do
      {:ok, _updated_request} ->
        # Log the admin denial action
        Elektrine.AuditLog.log(
          admin.id,
          "deny",
          "deletion_request",
          target_user_id: request.user_id,
          details: %{
            request_id: request.id,
            admin_notes: admin_notes,
            requested_at: request.inserted_at
          },
          ip_address: get_remote_ip(conn),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        )

        conn
        |> put_flash(:info, "Account deletion request denied.")
        |> redirect(to: ~p"/pripyat/deletion-requests")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to deny deletion request.")
        |> redirect(to: ~p"/pripyat/deletion-requests/#{id}")
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_flash(:error, "Deletion request not found")
      |> redirect(to: ~p"/pripyat/deletion-requests")
  end

  def deny(conn, %{"id" => id}) do
    deny(conn, %{"id" => id, "admin_notes" => ""})
  end

  defp get_remote_ip(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp approve_selected_requests(request_ids, admin, admin_notes, conn) do
    Enum.reduce(request_ids, {0, 0}, fn request_id, {approved_count, skipped_count} ->
      try do
        case Accounts.get_deletion_request!(request_id) do
          %{status: "pending"} = request ->
            case Accounts.review_deletion_request(request, admin, "approved", %{
                   admin_notes: admin_notes
                 }) do
              {:ok, _updated_request} ->
                log_approval(conn, admin, request, admin_notes)
                {approved_count + 1, skipped_count}

              {:error, _reason} ->
                {approved_count, skipped_count + 1}
            end

          _request ->
            {approved_count, skipped_count + 1}
        end
      rescue
        Ecto.NoResultsError ->
          {approved_count, skipped_count + 1}
      end
    end)
  end

  defp log_approval(conn, admin, request, admin_notes) do
    Elektrine.AuditLog.log(
      admin.id,
      "approve",
      "deletion_request",
      details: %{
        request_id: request.id,
        deleted_user_id: request.user_id,
        deleted_username: request.user.username,
        admin_notes: admin_notes,
        requested_at: request.inserted_at,
        bulk: true
      },
      ip_address: get_remote_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    )
  end

  defp flash_kind(approved_count) when approved_count > 0, do: :info
  defp flash_kind(_approved_count), do: :error

  defp bulk_approval_message(approved_count, skipped_count) do
    cond do
      approved_count > 0 and skipped_count == 0 ->
        "Approved #{approved_count} deletion request(s) and deleted the selected account(s)."

      approved_count > 0 ->
        "Approved #{approved_count} deletion request(s). Skipped #{skipped_count} request(s) that were missing, already reviewed, or failed."

      true ->
        "None of the selected requests could be approved. They may already be reviewed or no longer exist."
    end
  end
end
