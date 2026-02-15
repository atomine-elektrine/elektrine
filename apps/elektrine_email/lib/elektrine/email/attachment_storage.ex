defmodule Elektrine.Email.AttachmentStorage do
  @moduledoc """
  Handles storage and retrieval of email attachments in S3/R2.
  """

  require Logger
  alias ExAws.S3
  alias Elektrine.Telemetry.Events

  @doc """
  Uploads an email attachment to S3/R2 and returns the storage metadata.
  """
  def upload_attachment(mailbox_id, message_id, attachment_id, content, metadata \\ %{}) do
    bucket = get_bucket()
    key = generate_key(mailbox_id, message_id, attachment_id, metadata["filename"])
    bytes = byte_size(content)

    # Prepare upload options
    opts = [
      content_type: metadata["content_type"] || "application/octet-stream",
      metadata: %{
        "mailbox-id" => to_string(mailbox_id),
        "message-id" => to_string(message_id),
        "attachment-id" => attachment_id,
        "original-filename" => metadata["filename"] || "attachment"
      }
    ]

    # Upload to S3/R2
    case S3.put_object(bucket, key, content, opts) |> ExAws.request() do
      {:ok, _result} ->
        Logger.info("Successfully uploaded attachment #{attachment_id} for message #{message_id}")

        Events.upload(:email_attachment, :success, bytes, %{
          source: "s3"
        })

        {:ok,
         %{
           "storage_type" => "s3",
           "bucket" => bucket,
           "key" => key,
           "size" => byte_size(content),
           "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, error} ->
        Logger.error("Failed to upload attachment: #{inspect(error)}")
        Events.upload(:email_attachment, :failure, bytes, %{reason: inspect(error), source: "s3"})
        {:error, "Failed to upload attachment"}
    end
  end

  @doc """
  Downloads an attachment from S3/R2.
  """
  def download_attachment(storage_metadata) when is_map(storage_metadata) do
    case storage_metadata do
      %{"storage_type" => "s3", "bucket" => bucket, "key" => key} ->
        download_from_s3(bucket, key)

      %{"data" => data} when is_binary(data) ->
        # Legacy: attachment stored in database
        content = decode_attachment_data(data, storage_metadata)

        Events.upload(:email_attachment_download, :success, byte_size(content), %{
          source: "legacy"
        })

        {:ok, content}

      _ ->
        Events.upload(:email_attachment_download, :failure, nil, %{
          reason: :invalid_storage_metadata
        })

        {:error, "Invalid storage metadata"}
    end
  end

  @doc """
  Generates a presigned URL for direct attachment download.
  """
  def generate_presigned_url(storage_metadata, expires_in \\ 3600) do
    case storage_metadata do
      %{"storage_type" => "s3", "bucket" => bucket, "key" => key} ->
        config = ExAws.Config.new(:s3)

        {:ok, url} =
          ExAws.S3.presigned_url(config, :get, bucket, key,
            expires_in: expires_in,
            virtual_host: false,
            query_params: [{"response-content-disposition", "inline"}]
          )

        Events.upload(:email_attachment_presigned_url, :success, nil, %{source: "s3"})
        {:ok, url}

      _ ->
        Events.upload(:email_attachment_presigned_url, :failure, nil, %{
          reason: :invalid_storage_metadata
        })

        {:error, "Presigned URLs only available for S3 storage"}
    end
  end

  @doc """
  Deletes an attachment from S3/R2.
  """
  def delete_attachment(storage_metadata) do
    case storage_metadata do
      %{"storage_type" => "s3", "bucket" => bucket, "key" => key} ->
        case S3.delete_object(bucket, key) |> ExAws.request() do
          {:ok, _} ->
            Logger.info("Deleted attachment from S3: #{key}")
            Events.upload(:email_attachment_delete, :success, nil, %{source: "s3"})
            :ok

          {:error, error} ->
            Logger.error("Failed to delete attachment: #{inspect(error)}")

            Events.upload(:email_attachment_delete, :failure, nil, %{
              reason: inspect(error),
              source: "s3"
            })

            {:error, error}
        end

      _ ->
        # Legacy attachment or invalid metadata - nothing to delete from S3
        Events.upload(:email_attachment_delete, :success, nil, %{source: "legacy"})
        :ok
    end
  end

  @doc """
  Migrates a legacy database-stored attachment to S3/R2.
  """
  def migrate_attachment_to_s3(mailbox_id, message_id, attachment_id, attachment_data) do
    # Extract content from legacy attachment
    content =
      decode_attachment_data(
        attachment_data["data"],
        attachment_data
      )

    # Upload to S3
    upload_attachment(
      mailbox_id,
      message_id,
      attachment_id,
      content,
      attachment_data
    )
  end

  # Private functions

  defp download_from_s3(bucket, key) do
    case S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: content}} ->
        Events.upload(:email_attachment_download, :success, byte_size(content), %{source: "s3"})
        {:ok, content}

      {:error, error} ->
        Logger.error("Failed to download attachment from S3: #{inspect(error)}")

        Events.upload(:email_attachment_download, :failure, nil, %{
          reason: inspect(error),
          source: "s3"
        })

        {:error, "Failed to download attachment"}
    end
  end

  defp decode_attachment_data(data, metadata) do
    case metadata["encoding"] do
      "base64" ->
        case Base.decode64(data) do
          {:ok, decoded} -> decoded
          :error -> data
        end

      _ ->
        data
    end
  end

  defp generate_key(mailbox_id, message_id, attachment_id, filename) do
    # Generate a unique key with folder structure
    # Format: email-attachments/mailbox_<id>/message_<id>/attachment_<id>/<filename>
    ext = Path.extname(filename || "")
    safe_filename = "#{attachment_id}#{ext}"

    "email-attachments/mailbox_#{mailbox_id}/message_#{message_id}/#{safe_filename}"
  end

  @doc """
  Gets the public URL for an attachment from its S3 key.
  """
  def get_attachment_url(s3_key) when is_binary(s3_key) do
    bucket = get_bucket()

    endpoint =
      Application.get_env(:elektrine, :uploads)[:endpoint] ||
        raise "R2_ENDPOINT not configured"

    "https://#{bucket}.#{endpoint}/#{s3_key}"
  end

  def get_attachment_url(_), do: nil

  defp get_bucket do
    Application.get_env(:elektrine, :uploads)[:bucket] ||
      raise "S3/R2 bucket not configured"
  end
end
