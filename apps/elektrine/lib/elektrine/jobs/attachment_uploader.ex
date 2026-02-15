defmodule Elektrine.Jobs.AttachmentUploader do
  @moduledoc """
  Background job to upload email attachments to S3/R2 asynchronously.
  This prevents SMTP connections from being held open during slow S3 uploads.
  """

  require Logger
  alias Elektrine.Email
  alias Elektrine.Email.AttachmentStorage

  @doc """
  Uploads attachments for a message from database to S3 asynchronously.
  """
  def upload_message_attachments(message_id) do
    case Email.get_message_internal(message_id) do
      nil ->
        Logger.error("Message #{message_id} not found for attachment upload")
        {:error, :message_not_found}

      message ->
        if message.attachments && map_size(message.attachments) > 0 do
          Logger.info(
            "Uploading #{map_size(message.attachments)} attachments for message #{message_id} to S3"
          )

          updated_attachments =
            upload_attachments_to_s3(
              message.mailbox_id,
              message.id,
              message.attachments
            )

          # Update message with S3 storage metadata
          case Email.update_message(message, %{attachments: updated_attachments}) do
            {:ok, _updated_message} ->
              Logger.info("Successfully uploaded all attachments for message #{message_id}")
              :ok

            {:error, changeset} ->
              Logger.error(
                "Failed to update message #{message_id} with S3 metadata: #{inspect(changeset.errors)}"
              )

              {:error, :update_failed}
          end
        else
          :ok
        end
    end
  end

  # Upload attachments to S3 and return updated metadata
  defp upload_attachments_to_s3(mailbox_id, message_id, attachments) when is_map(attachments) do
    attachments
    |> Enum.map(fn {attachment_id, attachment_data} ->
      # Check if attachment already uploaded to S3
      if attachment_data["storage_type"] == "s3" do
        # Already in S3, keep as-is
        {attachment_id, attachment_data}
      else
        # Upload to S3
        case upload_single_attachment(mailbox_id, message_id, attachment_id, attachment_data) do
          {:ok, storage_metadata} ->
            # Merge S3 metadata and remove the data field to save DB space
            updated_data =
              Map.merge(attachment_data, storage_metadata)
              |> Map.delete("data")
              |> Map.delete("content")

            {attachment_id, updated_data}

          {:error, reason} ->
            Logger.error("Failed to upload attachment #{attachment_id}: #{inspect(reason)}")
            # Keep original attachment data if upload fails
            {attachment_id, attachment_data}
        end
      end
    end)
    |> Enum.into(%{})
  end

  defp upload_single_attachment(mailbox_id, message_id, attachment_id, attachment_data) do
    # Extract content from attachment data
    content =
      case attachment_data["data"] || attachment_data["content"] do
        nil ->
          Logger.error("No data found for attachment #{attachment_id}")
          nil

        data when is_binary(data) ->
          # Decode base64 if needed
          case attachment_data["encoding"] || "base64" do
            "base64" ->
              case Base.decode64(data) do
                {:ok, decoded} ->
                  decoded

                :error ->
                  Logger.warning(
                    "Failed to decode base64 for attachment #{attachment_id}, using as-is"
                  )

                  data
              end

            _ ->
              data
          end

        data ->
          Logger.warning("Unexpected data type for attachment #{attachment_id}: #{inspect(data)}")
          data
      end

    if content do
      # Upload to S3/R2
      AttachmentStorage.upload_attachment(
        mailbox_id,
        message_id,
        attachment_id,
        content,
        attachment_data
      )
    else
      {:error, "No content to upload"}
    end
  end
end
