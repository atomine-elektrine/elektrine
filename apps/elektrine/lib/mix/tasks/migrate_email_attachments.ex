defmodule Mix.Tasks.Elektrine.MigrateEmailAttachments do
  @moduledoc """
  Migrates existing email attachments from database storage to S3/R2.

  Usage:
    mix elektrine.migrate_email_attachments [--batch-size 100] [--dry-run]

  Options:
    --batch-size: Number of messages to process at once (default: 100)
    --dry-run: Show what would be migrated without actually doing it
  """

  use Mix.Task
  import Ecto.Query
  require Logger

  alias Elektrine.Repo
  alias Elektrine.Email.{Message, AttachmentStorage}

  @shortdoc "Migrates email attachments from database to S3/R2"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [batch_size: :integer, dry_run: :boolean],
        aliases: [b: :batch_size, d: :dry_run]
      )

    batch_size = opts[:batch_size] || 100
    dry_run = opts[:dry_run] || false

    Logger.info("Starting email attachment migration to S3/R2")
    Logger.info("Batch size: #{batch_size}")
    Logger.info("Dry run: #{dry_run}")

    migrate_attachments(batch_size, dry_run)
  end

  defp migrate_attachments(batch_size, dry_run) do
    # Find messages with attachments that haven't been migrated
    query =
      from m in Message,
        where: m.has_attachments == true,
        order_by: [asc: m.id],
        limit: ^batch_size

    messages = Repo.all(query)
    total_count = length(messages)

    if total_count == 0 do
      Logger.info("No messages with attachments found to migrate")
    else
      Logger.info("Processing #{total_count} messages with attachments")

      Enum.each(messages, fn message ->
        migrate_message_attachments(message, dry_run)
      end)

      Logger.info("Migration batch completed")

      # Continue with next batch if there are more
      if total_count == batch_size do
        Logger.info("Processing next batch...")
        migrate_attachments(batch_size, dry_run)
      else
        Logger.info("All messages processed")
      end
    end
  end

  defp migrate_message_attachments(message, dry_run) do
    if message.attachments && map_size(message.attachments) > 0 do
      Logger.info(
        "Processing message #{message.id} with #{map_size(message.attachments)} attachments"
      )

      updated_attachments =
        Enum.reduce(message.attachments, %{}, fn {attachment_id, attachment_data}, acc ->
          # Check if already migrated to S3
          if Map.get(attachment_data, "storage_type") == "s3" do
            Map.put(acc, attachment_id, attachment_data)
          else
            # Check if has data to migrate
            if Map.get(attachment_data, "data") do
              if dry_run do
                Logger.info(
                  "Would migrate attachment #{attachment_id} (#{Map.get(attachment_data, "size", 0)} bytes)"
                )

                Map.put(acc, attachment_id, attachment_data)
              else
                migrate_single_attachment(message, attachment_id, attachment_data, acc)
              end
            else
              Logger.warning("Attachment #{attachment_id} has no data, skipping")
              Map.put(acc, attachment_id, attachment_data)
            end
          end
        end)

      unless dry_run do
        # Update message with migrated attachments
        case Repo.update(Message.changeset(message, %{attachments: updated_attachments})) do
          {:ok, _updated} ->
            Logger.info("Successfully updated message #{message.id}")

          {:error, reason} ->
            Logger.error("Failed to update message #{message.id}: #{inspect(reason)}")
        end
      end
    end
  end

  defp migrate_single_attachment(message, attachment_id, attachment_data, acc) do
    Logger.info("Migrating attachment #{attachment_id}...")

    case AttachmentStorage.migrate_attachment_to_s3(
           message.mailbox_id,
           message.id,
           attachment_id,
           attachment_data
         ) do
      {:ok, storage_metadata} ->
        Logger.info("Successfully migrated attachment #{attachment_id} to S3")

        # Update attachment metadata with S3 info
        updated_data =
          attachment_data
          |> Map.merge(storage_metadata)
          # Remove base64 data
          |> Map.delete("data")

        Map.put(acc, attachment_id, updated_data)

      {:error, error} ->
        Logger.error("Failed to migrate attachment #{attachment_id}: #{inspect(error)}")
        # Keep original on failure
        Map.put(acc, attachment_id, attachment_data)
    end
  end
end
