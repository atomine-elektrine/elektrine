defmodule ElektrineEmailWeb.JMAP.BlobController do
  @moduledoc "JMAP Blob controller for upload and download operations.\nHandles attachment and message blob storage.\n"
  use ElektrineEmailWeb, :controller
  alias Elektrine.Email
  alias Elektrine.Security.FilePath
  @max_upload_size 52_428_800
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
  @doc "GET /jmap/download/:account_id/:blob_id/:name\nDownloads a blob (attachment or message).\n"
  def download(conn, %{"account_id" => account_id, "blob_id" => blob_id, "name" => name}) do
    user = conn.assigns[:current_user]
    expected_account_id = conn.assigns[:jmap_account_id]

    if account_id != expected_account_id or not valid_blob_id?(blob_id) do
      conn |> put_status(404) |> json(%{"type" => "blobNotFound"})
    else
      case get_blob(blob_id, user) do
        {:ok, content, content_type} ->
          safe_content_type = sanitize_content_type(content_type)
          safe_name = sanitize_filename(name)

          conn
          |> put_resp_content_type(safe_content_type)
          |> put_resp_header("content-disposition", "attachment; filename=\"#{safe_name}\"")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_resp(200, content)

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{"type" => "blobNotFound"})
      end
    end
  end

  defp valid_blob_id?(blob_id) do
    Regex.match?(~r/^[a-zA-Z0-9\-]+$/, blob_id)
  end

  defp sanitize_content_type(content_type) do
    base_type =
      content_type |> String.split(";") |> List.first() |> String.trim() |> String.downcase()

    cond do
      active_content_type?(base_type) ->
        "application/octet-stream"

      base_type in @allowed_content_types ->
        base_type

      true ->
        "application/octet-stream"
    end
  end

  defp active_content_type?(content_type) do
    content_type in [
      "text/html",
      "text/xml",
      "text/javascript",
      "text/css",
      "application/javascript",
      "application/ecmascript",
      "application/xml",
      "application/xhtml+xml",
      "image/svg+xml"
    ]
  end

  defp sanitize_filename(name) do
    name |> String.replace(~r/[^\w\.\-]/, "_") |> String.slice(0, 255)
  end

  @doc "POST /jmap/upload/:account_id\nUploads a blob for use in email composition.\n"
  def upload(conn, %{"account_id" => account_id}) do
    user = conn.assigns[:current_user]
    expected_account_id = conn.assigns[:jmap_account_id]

    if account_id != expected_account_id do
      conn |> put_status(403) |> json(%{"type" => "forbidden"})
    else
      case Plug.Conn.read_body(conn, length: @max_upload_size) do
        {:ok, body, conn} ->
          content_type =
            case get_req_header(conn, "content-type") do
              [ct | _] -> sanitize_content_type(ct)
              [] -> "application/octet-stream"
            end

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

        {:more, _partial, conn} ->
          conn
          |> put_status(:payload_too_large)
          |> json(%{"type" => "tooLarge", "description" => "Upload exceeds maximum size"})

        {:error, _reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{"type" => "invalidRequest", "description" => "Unable to read upload body"})
      end
    end
  end

  defp get_blob(blob_id, user) do
    if String.starts_with?(blob_id, "blob-") do
      get_stored_blob(blob_id, user)
    else
      get_message_blob(blob_id, user)
    end
  end

  defp get_stored_blob(blob_id, user) do
    case get_config(:adapter) do
      :local -> get_blob_local(blob_id, user.id)
      :s3 -> get_blob_s3(blob_id, user.id)
      _ -> get_blob_local(blob_id, user.id)
    end
  end

  defp get_blob_local(blob_id, user_id) do
    uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
    base_dir = Path.join(uploads_dir, "jmap-blobs")
    filename = "#{user_id}_#{blob_id}"
    path = Path.join(base_dir, filename)

    case FilePath.validate_existing_file(path, base_dir) do
      {:ok, safe_path} ->
        case File.read(safe_path) do
          {:ok, content} ->
            content_type = read_blob_meta_content_type(safe_path <> ".meta", base_dir)
            {:ok, content, content_type}

          {:error, _} ->
            {:error, :not_found}
        end

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp read_blob_meta_content_type(meta_path, base_dir) do
    with {:ok, safe_meta_path} <- FilePath.validate_existing_file(meta_path, base_dir),
         {:ok, meta} <- File.read(safe_meta_path) do
      sanitize_content_type(String.trim(meta))
    else
      _ -> "application/octet-stream"
    end
  end

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

  defp get_message_blob(blob_id, user) do
    message_id_str = String.replace_prefix(blob_id, "blob-", "")

    case Integer.parse(message_id_str) do
      {message_id, ""} ->
        mailbox = Email.get_user_mailbox(user.id)

        case Email.get_message(message_id, mailbox.id) do
          nil ->
            {:error, :not_found}

          message ->
            message = Email.Message.decrypt_content(message, user.id)
            content = build_raw_message(message)
            {:ok, content, "message/rfc822"}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp store_blob(blob_id, content, content_type, user) do
    case get_config(:adapter) do
      :local -> store_blob_local(blob_id, content, content_type, user.id)
      :s3 -> store_blob_s3(blob_id, content, content_type, user.id)
      _ -> store_blob_local(blob_id, content, content_type, user.id)
    end
  end

  defp store_blob_local(blob_id, content, content_type, user_id) do
    uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
    target_dir = Path.join(uploads_dir, "jmap-blobs")
    filename = "#{user_id}_#{blob_id}"
    filepath = Path.join(target_dir, filename)

    with {:ok, safe_path} <- FilePath.validate_child_path(filepath, target_dir),
         :ok <- File.mkdir_p(target_dir),
         :ok <- File.write(safe_path, content),
         :ok <- File.write(safe_path <> ".meta", content_type) do
      {:ok, safe_path}
    else
      {:error, :unsafe_path} -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_blob_s3(blob_id, content, content_type, user_id) do
    bucket = get_config(:bucket)
    key = "jmap-blobs/#{user_id}_#{blob_id}"

    case ExAws.S3.put_object(bucket, key, content, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_raw_message(message) do
    date = format_date(message.inserted_at)

    headers = [
      "From: #{safe_header_value(message.from)}",
      "To: #{safe_header_value(message.to)}",
      if message.cc do
        "Cc: #{safe_header_value(message.cc)}"
      else
        nil
      end,
      "Subject: #{safe_header_value(message.subject || "")}",
      "Message-ID: #{safe_header_value(message.message_id)}",
      "Date: #{date}",
      "MIME-Version: 1.0"
    ]

    {content_type, body} =
      cond do
        message.html_body && message.text_body ->
          boundary = "----=_Part_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
          multipart_body = "--#{boundary}
Content-Type: text/plain; charset=utf-8

#{message.text_body}

--#{boundary}
Content-Type: text/html; charset=utf-8

#{message.html_body}

--#{boundary}--
"
          {"multipart/alternative; boundary=\"#{boundary}\"", multipart_body}

        message.html_body ->
          {"text/html; charset=utf-8", message.html_body}

        true ->
          {"text/plain; charset=utf-8", message.text_body || ""}
      end

    headers = headers ++ ["Content-Type: #{content_type}"]

    headers
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n\r\n")
    |> Kernel.<>(body)
  end

  defp safe_header_value(value) do
    value
    |> to_string()
    |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
    |> String.trim()
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp get_config(key) do
    Application.get_env(:elektrine, :uploads, []) |> Keyword.get(key)
  end
end
