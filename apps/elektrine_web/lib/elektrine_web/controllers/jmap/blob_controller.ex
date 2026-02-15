defmodule ElektrineWeb.JMAP.BlobController do
  @moduledoc """
  JMAP Blob controller for upload and download operations.
  Handles attachment and message blob storage.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Email

  # 50 MB
  @max_upload_size 52_428_800

  # Allowed content types for blob storage
  @allowed_content_types ~w(
    application/octet-stream application/pdf application/zip application/json
    application/xml application/javascript application/x-www-form-urlencoded
    text/plain text/html text/css text/csv text/xml
    image/jpeg image/png image/gif image/webp image/svg+xml image/x-icon
    audio/mpeg audio/ogg audio/wav audio/webm
    video/mp4 video/webm video/ogg
    font/woff font/woff2 font/ttf font/otf
    message/rfc822
  )

  @doc """
  GET /jmap/download/:account_id/:blob_id/:name
  Downloads a blob (attachment or message).
  """
  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  def download(conn, %{"account_id" => account_id, "blob_id" => blob_id, "name" => name}) do
    user = conn.assigns[:current_user]
    expected_account_id = conn.assigns[:jmap_account_id]

    # Validate blob_id format to prevent directory traversal
    if account_id != expected_account_id or not valid_blob_id?(blob_id) do
      conn
      |> put_status(404)
      |> json(%{"type" => "blobNotFound"})
    else
      case get_blob(blob_id, user) do
        {:ok, content, content_type} ->
          # Sanitize content type
          safe_content_type = sanitize_content_type(content_type)
          # Sanitize filename
          safe_name = sanitize_filename(name)

          conn
          |> put_resp_content_type(safe_content_type)
          |> put_resp_header("content-disposition", "attachment; filename=\"#{safe_name}\"")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_resp(200, content)

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{"type" => "blobNotFound"})
      end
    end
  end

  # Validate blob_id contains only safe characters (alphanumeric, hyphens)
  defp valid_blob_id?(blob_id) do
    Regex.match?(~r/^[a-zA-Z0-9\-]+$/, blob_id)
  end

  # Sanitize content type to prevent header injection
  defp sanitize_content_type(content_type) do
    # Extract just the mime type, ignore parameters
    base_type =
      content_type |> String.split(";") |> List.first() |> String.trim() |> String.downcase()

    if base_type in @allowed_content_types do
      base_type
    else
      "application/octet-stream"
    end
  end

  # Sanitize filename to prevent header injection
  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^\w\.\-]/, "_")
    |> String.slice(0, 255)
  end

  @doc """
  POST /jmap/upload/:account_id
  Uploads a blob for use in email composition.
  """
  def upload(conn, %{"account_id" => account_id}) do
    user = conn.assigns[:current_user]
    expected_account_id = conn.assigns[:jmap_account_id]

    if account_id != expected_account_id do
      conn
      |> put_status(403)
      |> json(%{"type" => "forbidden"})
    else
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: @max_upload_size)

      content_type =
        case get_req_header(conn, "content-type") do
          [ct | _] -> sanitize_content_type(ct)
          [] -> "application/octet-stream"
        end

      # Generate blob ID (only alphanumeric and hyphens)
      blob_id = "blob-#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}"

      case store_blob(blob_id, body, content_type, user) do
        {:ok, _key} ->
          conn
          |> put_status(201)
          |> json(%{
            "accountId" => account_id,
            "blobId" => blob_id,
            "type" => content_type,
            "size" => byte_size(body)
          })

        {:error, _reason} ->
          conn
          |> put_status(500)
          |> json(%{"type" => "serverFail", "description" => "Upload failed"})
      end
    end
  end

  # Get blob content by ID
  defp get_blob(blob_id, user) do
    if String.starts_with?(blob_id, "blob-") do
      # JMAP blob (uploaded via /jmap/upload)
      get_stored_blob(blob_id, user)
    else
      # Message blob (email content as RFC822)
      get_message_blob(blob_id, user)
    end
  end

  # Get uploaded blob from storage
  defp get_stored_blob(blob_id, user) do
    # Try local storage first, then S3
    case get_config(:adapter) do
      :local ->
        get_blob_local(blob_id, user.id)

      :s3 ->
        get_blob_s3(blob_id, user.id)

      _ ->
        # Default to local
        get_blob_local(blob_id, user.id)
    end
  end

  # Get blob from local storage
  # sobelow_skip ["Traversal.FileModule"]
  defp get_blob_local(blob_id, user_id) do
    # blob_id is already validated by valid_blob_id?/1 (alphanumeric + hyphen only)
    # user_id is an integer from the database
    # safe_path?/2 verifies the path stays within base_dir
    uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
    base_dir = Path.join(uploads_dir, "jmap-blobs")

    # Construct safe filename using validated blob_id and integer user_id
    filename = "#{user_id}_#{blob_id}"
    path = Path.join(base_dir, filename)

    # Verify path is still within base_dir (defense in depth)
    if safe_path?(path, base_dir) do
      case File.read(path) do
        {:ok, content} ->
          content_type =
            case File.read(path <> ".meta") do
              {:ok, meta} -> sanitize_content_type(String.trim(meta))
              _ -> "application/octet-stream"
            end

          {:ok, content, content_type}

        {:error, _} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # Verify path doesn't escape base directory
  defp safe_path?(path, base_dir) do
    abs_path = Path.expand(path)
    abs_base = Path.expand(base_dir)
    String.starts_with?(abs_path, abs_base <> "/") or abs_path == abs_base
  end

  # Get blob from S3
  defp get_blob_s3(blob_id, user_id) do
    bucket = get_config(:bucket)
    key = "jmap-blobs/#{user_id}_#{blob_id}"

    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: content, headers: headers}} ->
        content_type =
          headers
          |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
          |> case do
            {_, ct} -> ct
            nil -> "application/octet-stream"
          end

        {:ok, content, content_type}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  # Get message content as RFC822 blob
  defp get_message_blob(blob_id, user) do
    # Parse message ID from blob-{id} format
    message_id_str = String.replace_prefix(blob_id, "blob-", "")

    case Integer.parse(message_id_str) do
      {message_id, ""} ->
        mailbox = Email.get_user_mailbox(user.id)

        case Email.get_message(message_id, mailbox.id) do
          nil ->
            {:error, :not_found}

          message ->
            # Decrypt message content if encrypted
            message = Email.Message.decrypt_content(message, user.id)
            content = build_raw_message(message)
            {:ok, content, "message/rfc822"}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # Store blob to storage
  defp store_blob(blob_id, content, content_type, user) do
    case get_config(:adapter) do
      :local ->
        store_blob_local(blob_id, content, content_type, user.id)

      :s3 ->
        store_blob_s3(blob_id, content, content_type, user.id)

      _ ->
        # Default to local
        store_blob_local(blob_id, content, content_type, user.id)
    end
  end

  # Store blob to local filesystem
  # sobelow_skip ["Traversal.FileModule"]
  defp store_blob_local(blob_id, content, content_type, user_id) do
    # blob_id is generated internally as "blob-{hex}" with safe characters only
    # user_id is an integer from the database
    # safe_path?/2 verifies the path stays within target_dir
    uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
    target_dir = Path.join(uploads_dir, "jmap-blobs")

    # Construct safe filename
    filename = "#{user_id}_#{blob_id}"
    filepath = Path.join(target_dir, filename)

    # Verify path stays within target directory
    unless safe_path?(filepath, target_dir) do
      {:error, :invalid_path}
    else
      File.mkdir_p!(target_dir)

      with :ok <- File.write(filepath, content),
           :ok <- File.write(filepath <> ".meta", content_type) do
        {:ok, filepath}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Store blob to S3
  defp store_blob_s3(blob_id, content, content_type, user_id) do
    bucket = get_config(:bucket)
    key = "jmap-blobs/#{user_id}_#{blob_id}"

    case ExAws.S3.put_object(bucket, key, content, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} ->
        {:ok, key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build raw RFC822 message from stored message
  defp build_raw_message(message) do
    date = format_date(message.inserted_at)

    headers = [
      "From: #{message.from}",
      "To: #{message.to}",
      if(message.cc, do: "Cc: #{message.cc}", else: nil),
      "Subject: #{message.subject || ""}",
      "Message-ID: #{message.message_id}",
      "Date: #{date}",
      "MIME-Version: 1.0"
    ]

    # Build body based on available content
    {content_type, body} =
      cond do
        message.html_body && message.text_body ->
          boundary = "----=_Part_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"

          multipart_body = """
          --#{boundary}
          Content-Type: text/plain; charset=utf-8

          #{message.text_body}

          --#{boundary}
          Content-Type: text/html; charset=utf-8

          #{message.html_body}

          --#{boundary}--
          """

          {"multipart/alternative; boundary=\"#{boundary}\"", multipart_body}

        message.html_body ->
          {"text/html; charset=utf-8", message.html_body}

        true ->
          {"text/plain; charset=utf-8", message.text_body || ""}
      end

    headers = headers ++ ["Content-Type: #{content_type}"]

    # Combine headers and body
    headers
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n\r\n")
    |> Kernel.<>(body)
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp get_config(key) do
    Application.get_env(:elektrine, :uploads, []) |> Keyword.get(key)
  end
end
