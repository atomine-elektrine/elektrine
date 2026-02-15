defmodule ElektrineWeb.API.ExportController do
  @moduledoc """
  API controller for data exports.

  Allows users to request exports of their data in various formats.
  Exports are processed asynchronously via Oban workers.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Developer
  alias Elektrine.Developer.DataExport

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/exports
  Lists recent exports for the authenticated user.
  """
  def index(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 10)

    exports = Developer.list_exports(user.id, limit: limit)

    conn
    |> put_status(:ok)
    |> json(%{
      exports: Enum.map(exports, &format_export/1)
    })
  end

  @doc """
  POST /api/export
  Creates a new export request.

  Params:
    - type: One of "email", "social", "chat", "contacts", "calendar", "account", "full"
    - format: One of "json", "csv", "mbox", "vcf", "ical", "zip" (optional, defaults to "json")
    - filters: Optional map of filters (e.g., date range)
  """
  def create(conn, params) do
    user = conn.assigns[:current_user]

    export_type = params["type"] || params["export_type"]
    format = params["format"] || "json"
    filters = params["filters"] || %{}

    if is_nil(export_type) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required parameter: type"})
    else
      attrs = %{
        export_type: export_type,
        format: format,
        filters: filters
      }

      case Developer.create_export(user.id, attrs) do
        {:ok, export} ->
          # Enqueue the export worker
          %{export_id: export.id}
          |> Elektrine.Developer.ExportWorker.new()
          |> Oban.insert()

          conn
          |> put_status(:accepted)
          |> json(%{
            message: "Export queued successfully",
            export: format_export(export)
          })

        {:error, changeset} ->
          errors = format_changeset_errors(changeset)

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to create export", details: errors})
      end
    end
  end

  @doc """
  GET /api/export/:id
  Gets the status of a specific export.
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Developer.get_export(user.id, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Export not found"})

      export ->
        conn
        |> put_status(:ok)
        |> json(%{export: format_export(export)})
    end
  end

  @doc """
  DELETE /api/export/:id
  Deletes an export and its file.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Developer.get_export(user.id, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Export not found"})

      export ->
        case Developer.delete_export(export) do
          {:ok, _} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Export deleted successfully"})

          {:error, _reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to delete export"})
        end
    end
  end

  @doc """
  GET /api/export/:id/download
  Downloads the export file.

  Requires a valid download_token query parameter.
  This endpoint does not require session authentication, only the token.
  """
  def download(conn, %{"id" => id} = params) do
    download_token = params["token"]

    if is_nil(download_token) || download_token == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing required parameter: token"})
    else
      case Developer.get_export_by_token(download_token) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Export not found or invalid token"})

        export ->
          # Verify the ID matches
          if to_string(export.id) != to_string(id) do
            conn
            |> put_status(:not_found)
            |> json(%{error: "Export not found"})
          else
            serve_export_file(conn, export)
          end
      end
    end
  end

  # Serve the export file for download
  defp serve_export_file(conn, export) do
    cond do
      not DataExport.downloadable?(export) ->
        conn
        |> put_status(:gone)
        |> json(%{error: "Export has expired or is not ready for download"})

      is_nil(export.file_path) or not File.exists?(export.file_path) ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Export file not found"})

      true ->
        # Record the download
        Developer.record_download(export)

        # Determine content type and filename
        {content_type, extension} = content_type_for_format(export.format)
        filename = "elektrine_#{export.export_type}_export_#{export.id}.#{extension}"

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_file(200, export.file_path)
    end
  end

  # Content types for each format
  defp content_type_for_format("json"), do: {"application/json", "json"}
  defp content_type_for_format("csv"), do: {"text/csv", "csv"}
  defp content_type_for_format("mbox"), do: {"application/mbox", "mbox"}
  defp content_type_for_format("vcf"), do: {"text/vcard", "vcf"}
  defp content_type_for_format("ical"), do: {"text/calendar", "ics"}
  defp content_type_for_format("zip"), do: {"application/zip", "zip"}
  defp content_type_for_format(_), do: {"application/octet-stream", "bin"}

  # Format export for JSON response
  defp format_export(%DataExport{} = export) do
    %{
      id: export.id,
      type: export.export_type,
      format: export.format,
      status: export.status,
      file_size: export.file_size,
      item_count: export.item_count,
      download_count: export.download_count,
      download_url: download_url(export),
      expires_at: export.expires_at,
      started_at: export.started_at,
      completed_at: export.completed_at,
      error: export.error,
      created_at: export.inserted_at
    }
  end

  # Generate download URL only for completed exports
  defp download_url(%DataExport{status: "completed", download_token: token, id: id}) do
    "/api/export/#{id}/download?token=#{token}"
  end

  defp download_url(_), do: nil

  # Format changeset errors for JSON response
  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end
end
