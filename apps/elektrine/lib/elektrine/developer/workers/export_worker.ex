defmodule Elektrine.Developer.ExportWorker do
  @moduledoc """
  Oban worker for processing data exports in the background.

  Supports exporting various data types (email, social, chat, etc.)
  in different formats (JSON, CSV, mbox, etc.).
  """
  use Oban.Worker,
    queue: :exports,
    max_attempts: 3,
    priority: 3

  require Logger

  alias Elektrine.Developer
  alias Elektrine.Developer.DataExport
  alias Elektrine.Developer.Exports.{EmailExporter, SocialExporter, ChatExporter, AccountExporter}

  # Export directory - configurable via :elektrine, :export_dir
  defp export_dir, do: Application.get_env(:elektrine, :export_dir, "/tmp/elektrine/exports")

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => export_id}}) do
    Logger.info("[ExportWorker] Starting export #{export_id}")

    # Get the export record
    case Elektrine.Repo.get(DataExport, export_id) do
      nil ->
        Logger.error("[ExportWorker] Export #{export_id} not found")
        {:error, :not_found}

      export ->
        process_export(export)
    end
  end

  defp process_export(%DataExport{} = export) do
    # Mark as processing
    {:ok, export} = Developer.start_export(export)

    try do
      # Ensure export directory exists
      File.mkdir_p!(export_dir())

      # Generate unique filename - sanitize user_id and export_type to prevent path traversal
      timestamp = DateTime.utc_now() |> DateTime.to_unix()
      safe_user_id = export.user_id |> to_string() |> String.replace(~r/[^0-9]/, "")
      safe_type = export.export_type |> String.replace(~r/[^a-z_]/, "")
      safe_format = export.format |> String.replace(~r/[^a-z]/, "")
      filename = "#{safe_user_id}_#{safe_type}_#{timestamp}.#{safe_format}"
      file_path = Path.join(export_dir(), filename)

      # Security: Verify the path doesn't escape the export directory
      expanded_path = Path.expand(file_path)
      expanded_dir = Path.expand(export_dir())

      unless String.starts_with?(expanded_path, expanded_dir <> "/") do
        raise "Security: Invalid export path detected"
      end

      # Run the appropriate exporter
      result = run_exporter(export, file_path)

      case result do
        {:ok, item_count} ->
          # Get file size
          file_size = File.stat!(file_path).size

          # Mark as completed
          {:ok, _export} = Developer.complete_export(export, file_path, file_size, item_count)

          Logger.info(
            "[ExportWorker] Export #{export.id} completed: #{item_count} items, #{file_size} bytes"
          )

          :ok

        {:error, reason} ->
          # Mark as failed
          {:ok, _export} = Developer.fail_export(export, inspect(reason))

          Logger.error("[ExportWorker] Export #{export.id} failed: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        # Mark as failed
        {:ok, _export} = Developer.fail_export(export, Exception.message(e))

        Logger.error("[ExportWorker] Export #{export.id} crashed: #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

  # Route to the appropriate exporter based on type
  defp run_exporter(%DataExport{export_type: "email"} = export, file_path) do
    EmailExporter.export(export.user_id, file_path, export.format, export.filters)
  end

  defp run_exporter(%DataExport{export_type: "social"} = export, file_path) do
    SocialExporter.export(export.user_id, file_path, export.format, export.filters)
  end

  defp run_exporter(%DataExport{export_type: "chat"} = export, file_path) do
    ChatExporter.export(export.user_id, file_path, export.format, export.filters)
  end

  defp run_exporter(%DataExport{export_type: "account"} = export, file_path) do
    AccountExporter.export(export.user_id, file_path, export.format, export.filters)
  end

  defp run_exporter(%DataExport{export_type: "contacts"} = export, file_path) do
    # Contacts are part of account data
    AccountExporter.export_contacts(export.user_id, file_path, export.format, export.filters)
  end

  defp run_exporter(%DataExport{export_type: "calendar"} = export, file_path) do
    # Calendar is part of account data
    AccountExporter.export_calendar(export.user_id, file_path, export.format, export.filters)
  end

  defp run_exporter(%DataExport{export_type: "full"} = export, file_path) do
    # Full export combines all data into a zip
    export_full(export.user_id, file_path, export.filters)
  end

  defp run_exporter(%DataExport{export_type: type}, _file_path) do
    {:error, "Unknown export type: #{type}"}
  end

  # Full export: combines all data types into a zip archive
  defp export_full(user_id, file_path, filters) do
    temp_dir = Path.join(export_dir(), "temp_#{user_id}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    try do
      # Export each type
      {:ok, email_count} =
        EmailExporter.export(user_id, Path.join(temp_dir, "emails.json"), "json", filters)

      {:ok, social_count} =
        SocialExporter.export(user_id, Path.join(temp_dir, "social.json"), "json", filters)

      {:ok, chat_count} =
        ChatExporter.export(user_id, Path.join(temp_dir, "messages.json"), "json", filters)

      {:ok, account_count} =
        AccountExporter.export(user_id, Path.join(temp_dir, "account.json"), "json", filters)

      total_count = email_count + social_count + chat_count + account_count

      # Create zip archive
      files =
        temp_dir
        |> File.ls!()
        |> Enum.map(fn file ->
          {String.to_charlist(file), File.read!(Path.join(temp_dir, file))}
        end)

      {:ok, _} = :zip.create(String.to_charlist(file_path), files)

      {:ok, total_count}
    after
      # Clean up temp directory
      File.rm_rf!(temp_dir)
    end
  end
end
