defmodule ElektrineWeb.Admin.DeletionRequestsController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

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

    # Log the admin approval action BEFORE deletion (while user still exists)
    Elektrine.AuditLog.log(
      admin.id,
      "approve",
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

    case Accounts.review_deletion_request(request, admin, "approved", %{admin_notes: admin_notes}) do
      {:ok, _updated_request} ->
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
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end
end
