defmodule ElektrineWeb.API.BackupController do
  @moduledoc """
  Account backup API backed by Elektrine data exports.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Developer
  alias Elektrine.Developer.DataExport

  @backup_types ~w(account full)

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    backups =
      Developer.list_exports(user.id, limit: 20)
      |> Enum.filter(&(&1.export_type in ["account", "full"]))
      |> Enum.map(&format_backup/1)

    json(conn, backups)
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]
    export_type = params["type"] || "full"
    format = params["format"] || "zip"

    with :ok <- validate_backup_type(export_type),
         :ok <- validate_backup_format(export_type, format),
         {:ok, export} <-
           Developer.create_export_and_enqueue(user.id, %{
             export_type: export_type,
             format: format,
             filters: params["filters"] || %{}
           }) do
      conn
      |> put_status(:accepted)
      |> json(format_backup(export))
    else
      {:error, :invalid_backup_type} ->
        bad_request(conn, "type must be account or full")

      {:error, :invalid_backup_format} ->
        bad_request(conn, "format is not valid for this backup type")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_backup_export(user.id, id) do
      nil -> not_found(conn)
      export -> json(conn, format_backup(export))
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case get_backup_export(user.id, id) do
      nil ->
        not_found(conn)

      export ->
        case Developer.delete_export(export) do
          {:ok, _export} -> json(conn, %{id: to_string(id), deleted: true})
          {:error, _reason} -> not_found(conn)
        end
    end
  end

  defp format_backup(export) do
    %{
      id: to_string(export.id),
      type: export.export_type,
      processed: export.status == "completed",
      inserted_at: export.inserted_at,
      created_at: export.inserted_at,
      file_size: export.file_size,
      status: export.status,
      url: download_url(export),
      download_url: download_url(export),
      authenticated_download_url: authenticated_download_url(export),
      expires_at: export.expires_at
    }
  end

  defp validate_backup_type(type) when type in @backup_types, do: :ok
  defp validate_backup_type(_), do: {:error, :invalid_backup_type}

  defp validate_backup_format(type, format) do
    if format in DataExport.formats_for_type(type) do
      :ok
    else
      {:error, :invalid_backup_format}
    end
  end

  defp get_backup_export(user_id, id) do
    case Developer.get_export(user_id, id) do
      %{export_type: type} = export when type in @backup_types -> export
      _ -> nil
    end
  end

  defp download_url(export), do: authenticated_download_url(export)

  defp authenticated_download_url(%{status: "completed", id: id} = export) do
    if DataExport.downloadable?(export), do: "/api/ext/v1/exports/#{id}/download"
  end

  defp authenticated_download_url(_), do: nil

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end
end
