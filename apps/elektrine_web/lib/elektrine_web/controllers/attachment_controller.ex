defmodule ElektrineWeb.AttachmentController do
  use ElektrineWeb, :controller

  alias Elektrine.Email
  alias Elektrine.Email.AttachmentStorage

  def download(conn, %{"message_id" => message_id_str, "attachment_id" => attachment_id}) do
    user = conn.assigns.current_user

    # Convert message_id to integer and validate
    case Integer.parse(message_id_str) do
      {message_id, ""} ->
        # Validate attachment_id format to prevent path traversal and injection attacks
        attachment_id = String.trim(attachment_id)

        # SECURITY: Strict validation to prevent path traversal
        # Reject any path separators, parent directory references, or null bytes
        cond do
          String.contains?(attachment_id, ["/", "\\", "\0", ".."]) ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Invalid attachment ID format"})

          # Accept formats: attachment_1234, 1_filename.jpg, 0_file name (8).jpg, temp_123_456, or simple numbers: 0, 1, 2
          # Allow only alphanumeric, dots, hyphens, underscores, spaces, and parentheses
          not Regex.match?(
            ~r/^(attachment_\d+|\d+_[\w\-\.\s\(\)]+|temp_\d+_\d+|\d+)$/,
            attachment_id
          ) ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Invalid attachment ID format"})

          # Additional safety: ensure it doesn't start with dot or dash
          String.starts_with?(attachment_id, ["..", ".", "-"]) ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Invalid attachment ID format"})

          true ->
            # Get the message and verify user owns it
            case Email.get_user_message(message_id, user.id) do
              {:ok, message} ->
                # Get the attachment data
                case Map.get(message.attachments, attachment_id) do
                  nil ->
                    conn
                    |> put_status(:not_found)
                    |> json(%{error: "Attachment not found"})

                  attachment ->
                    # Check if we should redirect to presigned URL or serve directly
                    if use_presigned_url?(attachment) do
                      # Generate presigned URL for direct download from S3/R2
                      case AttachmentStorage.generate_presigned_url(attachment) do
                        {:ok, url} ->
                          conn
                          |> put_status(:found)
                          |> redirect(external: url)

                        {:error, _reason} ->
                          # Fallback to direct download
                          serve_attachment_directly(conn, attachment)
                      end
                    else
                      # Serve attachment directly (for legacy or small files)
                      serve_attachment_directly(conn, attachment)
                    end
                end

              {:error, :message_not_found} ->
                conn
                |> put_status(:not_found)
                |> json(%{error: "Message not found"})

              {:error, _} ->
                conn
                |> put_status(:forbidden)
                |> json(%{error: "Access denied"})
            end
        end

      _ ->
        # Invalid message_id format (not a valid integer)
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid message ID format"})
    end
  end

  # SECURITY: Sanitize filename to prevent path traversal and XSS
  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    # Use basename to strip any path components
    |> Path.basename()
    # Remove dangerous characters that could be used in attacks
    |> String.replace(~r/[<>:"\/\\|?*\x00-\x1F]/, "_")
    # Limit length to prevent issues
    |> String.slice(0, 255)
    # Ensure it's not empty
    |> case do
      "" -> "download"
      name -> name
    end
  end

  defp sanitize_filename(_), do: "download"

  # Check if we should use presigned URL (for S3/R2 stored attachments)
  defp use_presigned_url?(attachment) do
    Map.get(attachment, "storage_type") == "s3"
  end

  # Serve attachment directly (for legacy or when presigned URL fails)
  defp serve_attachment_directly(conn, attachment) do
    case get_attachment_content(attachment) do
      {:ok, content, content_type} ->
        # SECURITY: Sanitize filename to prevent path traversal and XSS
        safe_filename = sanitize_filename(attachment["filename"] || "download")

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{safe_filename}\""
        )
        |> put_resp_header("content-length", "#{byte_size(content)}")
        |> send_resp(200, content)

      {:error, reason} ->
        require Logger
        Logger.error("Failed to serve attachment: #{reason}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to retrieve attachment: #{reason}"})
    end
  end

  # Get actual attachment content from storage
  defp get_attachment_content(attachment) do
    # Try to download from S3/R2 first
    case AttachmentStorage.download_attachment(attachment) do
      {:ok, content} ->
        content_type = Map.get(attachment, "content_type", "application/octet-stream")
        {:ok, content, content_type}

      {:error, _reason} ->
        # Fallback to legacy data field if S3 download fails
        case Map.get(attachment, "data") do
          nil ->
            {:error, "No attachment data available"}

          "" ->
            {:error, "Attachment data is empty"}

          data when is_binary(data) ->
            # Check if data is base64 encoded
            content =
              case Map.get(attachment, "encoding") do
                "base64" ->
                  case Base.decode64(data, ignore: :whitespace) do
                    {:ok, decoded} -> decoded
                    # If decode fails, use raw data
                    :error -> data
                  end

                _ ->
                  # Auto-detect base64: if it looks like base64 and decodes successfully, use decoded version
                  if String.match?(data, ~r/^[A-Za-z0-9+\/=\r\n\s]+$/) do
                    case Base.decode64(data, ignore: :whitespace) do
                      {:ok, decoded} -> decoded
                      # Not valid base64, use as-is
                      :error -> data
                    end
                  else
                    data
                  end
              end

            content_type = Map.get(attachment, "content_type", "application/octet-stream")
            {:ok, content, content_type}

          _ ->
            {:error, "Invalid attachment data format"}
        end
    end
  end
end
