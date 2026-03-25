defmodule Elektrine.Email.AttachmentStorage do
  @moduledoc """
  Handles storage and retrieval of email attachments in local or S3-compatible storage.
  """

  require Logger
  alias Elektrine.Telemetry.Events
  alias ExAws.S3

  @doc """
  Uploads an email attachment and returns the storage metadata.
  """
  def upload_attachment(mailbox_id, message_id, attachment_id, content, metadata \\ %{}) do
    key = generate_key(mailbox_id, message_id, attachment_id, metadata["filename"])
    bytes = byte_size(content)
    content_type = metadata["content_type"] || "application/octet-stream"

    case storage_adapter() do
      :local ->
        upload_attachment_local(key, content, content_type, bytes)

      :s3 ->
        upload_attachment_s3(
          key,
          content,
          content_type,
          metadata["filename"],
          mailbox_id,
          message_id,
          attachment_id,
          bytes
        )
    end
  end

  @doc """
  Downloads an attachment from S3/R2.
  """
  def download_attachment(storage_metadata) when is_map(storage_metadata) do
    case storage_metadata do
      %{"storage_type" => "s3", "bucket" => bucket, "key" => key} ->
        download_from_s3(bucket, key)

      %{"storage_type" => "local", "key" => key} ->
        download_from_local(key)

      %{"data" => data} when is_binary(data) ->
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
  Deletes an attachment from storage.
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

      %{"storage_type" => "local", "key" => key} ->
        delete_attachment_local(key)

      _ ->
        Events.upload(:email_attachment_delete, :success, nil, %{source: "legacy"})
        :ok
    end
  end

  @doc """
  Migrates a legacy database-stored attachment into configured attachment storage.
  """
  def migrate_attachment_to_s3(mailbox_id, message_id, attachment_id, attachment_data) do
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

  def stored_attachment?(attachment) when is_map(attachment) do
    Map.get(attachment, "storage_type") in ["local", "s3"]
  end

  def stored_attachment?(_), do: false

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

  defp download_from_local(key) do
    path = local_storage_path(key)

    case File.read(path) do
      {:ok, content} ->
        Events.upload(:email_attachment_download, :success, byte_size(content), %{source: "local"})

        {:ok, content}

      {:error, error} ->
        Logger.error("Failed to download attachment from local storage: #{inspect(error)}")

        Events.upload(:email_attachment_download, :failure, nil, %{
          reason: inspect(error),
          source: "local"
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
    ext = Path.extname(filename || "")
    safe_filename = "#{attachment_id}#{ext}"

    "email-attachments/mailbox_#{mailbox_id}/message_#{message_id}/#{safe_filename}"
  end

  @doc """
  Gets the public URL for an attachment from its S3 key.
  """
  def get_attachment_url(s3_key) when is_binary(s3_key) do
    case storage_adapter() do
      :local -> nil
      :s3 -> get_s3_attachment_url(s3_key)
    end
  end

  def get_attachment_url(_), do: nil

  defp upload_attachment_local(key, content, _content_type, bytes) do
    path = local_storage_path(key)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok ->
        Logger.info("Successfully uploaded attachment to local storage: #{key}")
        Events.upload(:email_attachment, :success, bytes, %{source: "local"})

        {:ok,
         %{
           "storage_type" => "local",
           "key" => key,
           "size" => bytes,
           "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, error} ->
        Logger.error("Failed to upload attachment to local storage: #{inspect(error)}")

        Events.upload(:email_attachment, :failure, bytes, %{
          reason: inspect(error),
          source: "local"
        })

        {:error, "Failed to upload attachment"}
    end
  end

  defp upload_attachment_s3(
         key,
         content,
         content_type,
         original_filename,
         mailbox_id,
         message_id,
         attachment_id,
         bytes
       ) do
    bucket = get_bucket()

    opts = [
      content_type: content_type,
      metadata: %{
        "mailbox-id" => to_string(mailbox_id),
        "message-id" => to_string(message_id),
        "attachment-id" => attachment_id,
        "original-filename" => original_filename || "attachment"
      }
    ]

    case S3.put_object(bucket, key, content, opts) |> ExAws.request() do
      {:ok, _result} ->
        Logger.info("Successfully uploaded attachment #{attachment_id} for message #{message_id}")
        Events.upload(:email_attachment, :success, bytes, %{source: "s3"})

        {:ok,
         %{
           "storage_type" => "s3",
           "bucket" => bucket,
           "key" => key,
           "size" => bytes,
           "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:error, error} ->
        Logger.error("Failed to upload attachment: #{inspect(error)}")
        Events.upload(:email_attachment, :failure, bytes, %{reason: inspect(error), source: "s3"})
        {:error, "Failed to upload attachment"}
    end
  end

  defp delete_attachment_local(key) do
    path = local_storage_path(key)

    case File.rm(path) do
      :ok ->
        Logger.info("Deleted attachment from local storage: #{key}")
        Events.upload(:email_attachment_delete, :success, nil, %{source: "local"})
        :ok

      {:error, :enoent} ->
        Events.upload(:email_attachment_delete, :success, nil, %{source: "local"})
        :ok

      {:error, error} ->
        Logger.error("Failed to delete local attachment: #{inspect(error)}")

        Events.upload(:email_attachment_delete, :failure, nil, %{
          reason: inspect(error),
          source: "local"
        })

        {:error, error}
    end
  end

  defp local_storage_path(key) do
    uploads_dir =
      Application.get_env(:elektrine, :uploads, [])[:uploads_dir] || "priv/static/uploads"

    Path.join(uploads_dir, key)
  end

  defp get_s3_attachment_url(s3_key) do
    bucket = get_bucket()

    endpoint =
      Application.get_env(:elektrine, :uploads)[:endpoint] ||
        raise "R2_ENDPOINT not configured"

    "https://#{bucket}.#{endpoint}/#{s3_key}"
  end

  defp storage_adapter do
    Application.get_env(:elektrine, :uploads, [])[:adapter] || :local
  end

  defp get_bucket do
    Application.get_env(:elektrine, :uploads)[:bucket] ||
      raise "S3/R2 bucket not configured"
  end
end
