defmodule Elektrine.Uploads do
  @moduledoc "Handles file uploads with support for both local storage and S3.\n\nConfiguration determines which adapter to use:\n- :local for development (stores files locally)\n- :s3 for production (stores files in S3)\n"
  require Logger
  alias Elektrine.Accounts
  alias Elektrine.Accounts.Storage
  alias Elektrine.Constants
  alias Elektrine.Telemetry.Events
  @default_max_file_size 5 * 1024 * 1024
  @default_max_background_size 10 * 1024 * 1024
  @allowed_mime_types ~w[
    image/jpeg
    image/jpg
    image/png
    image/gif
    image/webp
  ]
  @allowed_extensions ~w[.jpg .jpeg .png .gif .webp]
  @chat_attachment_mime_types ~w[
    image/jpeg
    image/jpg
    image/png
    image/gif
    image/webp
    video/mp4
    video/webm
    video/ogg
    video/quicktime
    audio/mpeg
    audio/mp3
    audio/ogg
    audio/wav
    audio/webm
    audio/aac
    audio/m4a
    audio/flac
    application/pdf
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    text/plain
  ]
  @chat_attachment_extensions ~w[.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav .m4a .aac .flac .pdf .doc .docx .xls .xlsx .txt]
  @max_chat_attachment_size Constants.max_chat_attachment_size()
  @background_mime_types ~w[
    image/jpeg
    image/jpg
    image/png
    image/gif
    image/webp
    video/mp4
    video/webm
  ]
  @background_extensions ~w[.jpg .jpeg .png .gif .webp .mp4 .webm]
  @favicon_mime_types ~w[
    image/png
    image/x-icon
    image/vnd.microsoft.icon
    image/svg+xml
    image/jpeg
    image/jpg
  ]
  @favicon_extensions ~w[.png .ico .svg .jpg .jpeg]
  @max_favicon_size Constants.max_favicon_size()
  @malicious_patterns [
    ~r/<?php/i,
    ~r/<\?=/i,
    ~r/eval\s*\(/i,
    ~r/exec\s*\(/i,
    ~r/system\s*\(/i,
    ~r/shell_exec\s*\(/i,
    ~r/<script/i,
    ~r/javascript:/i,
    ~r/on\w+\s*=/i,
    ~r/<iframe/i,
    ~r/<object/i,
    ~r/<embed/i,
    ~r/include\s*\(/i,
    ~r/require\s*\(/i,
    ~r/union\s+select/i,
    ~r/drop\s+table/i
  ]
  @magic_bytes %{
    "image/jpeg" => [<<255, 216, 255>>],
    "image/png" => [<<137, 80, 78, 71, 13, 10, 26, 10>>],
    "image/gif" => ["GIF87a", "GIF89a"],
    "image/webp" => ["RIFF"],
    "application/pdf" => [<<37, 80, 68, 70>>],
    "video/mp4" => [<<0, 0, 0>>, "ftyp"],
    "video/webm" => [<<26, 69, 223, 163>>]
  }
  @doc "Checks if user has enough storage quota for an upload.\nReturns :ok or {:error, :storage_limit_exceeded}\nAdmins bypass storage limits.\n"
  def check_user_storage_limit(user_id, file_size) do
    user = Accounts.get_user!(user_id)

    if user.is_admin || not Storage.would_exceed_limit?(user_id, file_size) do
      :ok
    else
      {:error, :storage_limit_exceeded}
    end
  end

  @doc "Uploads a file and returns the public URL.\n\nReturns {:ok, url} on success or {:error, reason} on failure.\n"
  def upload_avatar(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- check_user_storage_limit(user_id, file_size),
           :ok <- validate_upload(upload, user_id),
           {:ok, cropped_path} <- crop_avatar_to_square(upload.path) do
        {:ok, %File.Stat{size: cropped_size}} = File.stat(cropped_path)
        cropped_upload = %{upload | path: cropped_path}
        upload_result = upload_s3(cropped_upload, user_id, "avatars")
        File.rm(cropped_path)

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: cropped_size
             }}

          error ->
            error
        end
      else
        error ->
          Logger.error("Avatar upload failed for user #{user_id}: #{inspect(error)}")
          error
      end

    emit_upload_result(:avatar, result)
    result
  end

  def upload_background(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- validate_background_upload(upload, user_id),
           {:ok, processed_path} <- strip_metadata_if_image(upload) do
        upload_to_use =
          if processed_path != upload.path do
            %{upload | path: processed_path}
          else
            upload
          end

        upload_result =
          case get_config(:adapter) do
            :local -> upload_local(upload_to_use, user_id, "backgrounds")
            :s3 -> upload_s3(upload_to_use, user_id, "backgrounds")
          end

        if processed_path != upload.path do
          File.rm(processed_path)
        end

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: file_size
             }}

          error ->
            error
        end
      end

    emit_upload_result(:background, result)
    result
  end

  def upload_favicon(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- validate_favicon_upload(upload, user_id),
           {:ok, processed_path} <- strip_metadata_if_image(upload) do
        upload_to_use =
          if processed_path != upload.path do
            %{upload | path: processed_path}
          else
            upload
          end

        upload_result =
          case get_config(:adapter) do
            :local -> upload_local(upload_to_use, user_id, "favicons")
            :s3 -> upload_s3(upload_to_use, user_id, "favicons")
          end

        if processed_path != upload.path do
          File.rm(processed_path)
        end

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: file_size
             }}

          error ->
            error
        end
      end

    emit_upload_result(:favicon, result)
    result
  end

  @doc "Uploads a chat attachment (image or file) and returns the public URL.\n\nReturns {:ok, url} on success or {:error, reason} on failure.\n"
  def upload_chat_attachment(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- validate_chat_attachment_upload(upload, user_id),
           {:ok, processed_path} <- strip_metadata_if_image(upload) do
        upload_to_use =
          if processed_path != upload.path do
            %{upload | path: processed_path}
          else
            upload
          end

        upload_result =
          case get_config(:adapter) do
            :local -> upload_local(upload_to_use, user_id, "chat-attachments")
            :s3 -> upload_s3(upload_to_use, user_id, "chat-attachments")
          end

        if processed_path != upload.path do
          File.rm(processed_path)
        end

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: file_size
             }}

          error ->
            error
        end
      else
        error ->
          Logger.error("Chat attachment upload failed for user #{user_id}: #{inspect(error)}")
          error
      end

    emit_upload_result(:chat_attachment, result)
    result
  end

  @doc "Uploads a timeline post attachment (images, media).\n"
  def upload_timeline_attachment(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- validate_chat_attachment_upload(upload, user_id),
           {:ok, processed_path} <- strip_metadata_if_image(upload) do
        upload_to_use =
          if processed_path != upload.path do
            %{upload | path: processed_path}
          else
            upload
          end

        upload_result =
          case get_config(:adapter) do
            :local -> upload_local(upload_to_use, user_id, "timeline-attachments")
            :s3 -> upload_s3(upload_to_use, user_id, "timeline-attachments")
          end

        if processed_path != upload.path do
          File.rm(processed_path)
        end

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: file_size
             }}

          error ->
            error
        end
      else
        error ->
          Logger.error("Timeline attachment upload failed for user #{user_id}: #{inspect(error)}")
          error
      end

    emit_upload_result(:timeline_attachment, result)
    result
  end

  @doc "Uploads a gallery photo.\n"
  def upload_gallery_photo(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- validate_chat_attachment_upload(upload, user_id),
           {:ok, processed_path} <- strip_metadata_if_image(upload) do
        upload_to_use =
          if processed_path != upload.path do
            %{upload | path: processed_path}
          else
            upload
          end

        upload_result =
          case get_config(:adapter) do
            :local -> upload_local(upload_to_use, user_id, "gallery-attachments")
            :s3 -> upload_s3(upload_to_use, user_id, "gallery-attachments")
          end

        if processed_path != upload.path do
          File.rm(processed_path)
        end

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: file_size
             }}

          error ->
            error
        end
      else
        error ->
          Logger.error("Gallery photo upload failed for user #{user_id}: #{inspect(error)}")
          error
      end

    emit_upload_result(:gallery_photo, result)
    result
  end

  @doc "Uploads a voice message from binary audio data.\nReturns {:ok, metadata} on success or {:error, reason} on failure.\n"
  def upload_voice_message(audio_binary, filename, mime_type, user_id)
      when is_binary(audio_binary) do
    max_size = 10 * 1024 * 1024

    result =
      if byte_size(audio_binary) > max_size do
        {:error, :file_too_large}
      else
        file_size = byte_size(audio_binary)

        upload_result =
          case get_config(:adapter) do
            :local -> upload_binary_local(audio_binary, filename, user_id, "voice-messages")
            :s3 -> upload_binary_s3(audio_binary, filename, mime_type, user_id, "voice-messages")
          end

        case upload_result do
          {:ok, key} ->
            {:ok, %{key: key, filename: filename, content_type: mime_type, size: file_size}}

          error ->
            error
        end
      end

    emit_upload_result(:voice_message, result)
    result
  end

  defp upload_binary_local(binary, filename, user_id, folder) do
    uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
    target_dir = Path.join(uploads_dir, folder)
    File.mkdir_p!(target_dir)
    safe_filename = sanitize_filename(filename)
    unique_filename = "#{user_id}_#{System.unique_integer([:positive])}_#{safe_filename}"
    filepath = Path.join(target_dir, unique_filename)

    case File.write(filepath, binary) do
      :ok -> {:ok, "/uploads/#{folder}/#{unique_filename}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_binary_s3(binary, filename, mime_type, user_id, folder) do
    bucket = get_config(:bucket)
    _endpoint = get_config(:endpoint) || raise "R2_ENDPOINT not configured"
    safe_filename = sanitize_filename(filename)
    unique_filename = "#{user_id}_#{System.unique_integer([:positive])}_#{safe_filename}"
    key = "#{folder}/#{unique_filename}"

    case ExAws.S3.put_object(bucket, key, binary, content_type: mime_type) |> ExAws.request() do
      {:ok, _response} -> {:ok, key}
      {:error, reason} -> {:error, "Upload failed: #{inspect(reason)}"}
    end
  end

  @doc "Uploads a discussion post attachment.\n"
  def upload_discussion_attachment(%Plug.Upload{} = upload, user_id) do
    result =
      with {:ok, %File.Stat{size: file_size}} <- File.stat(upload.path),
           :ok <- validate_chat_attachment_upload(upload, user_id),
           {:ok, processed_path} <- strip_metadata_if_image(upload) do
        upload_to_use =
          if processed_path != upload.path do
            %{upload | path: processed_path}
          else
            upload
          end

        upload_result =
          case get_config(:adapter) do
            :local -> upload_local(upload_to_use, user_id, "discussion-attachments")
            :s3 -> upload_s3(upload_to_use, user_id, "discussion-attachments")
          end

        if processed_path != upload.path do
          File.rm(processed_path)
        end

        case upload_result do
          {:ok, key} ->
            {:ok,
             %{
               key: key,
               filename: upload.filename,
               content_type: upload.content_type,
               size: file_size
             }}

          error ->
            error
        end
      else
        error ->
          Logger.error(
            "Discussion attachment upload failed for user #{user_id}: #{inspect(error)}"
          )

          error
      end

    emit_upload_result(:discussion_attachment, result)
    result
  end

  defp validate_upload(%Plug.Upload{} = upload, user_id) do
    with :ok <- validate_file_size(upload, :avatar, user_id),
         :ok <- validate_file_type(upload, @allowed_mime_types),
         :ok <- validate_file_extension(upload, @allowed_extensions) do
      validate_avatar_content(upload)
    end
  end

  defp validate_background_upload(%Plug.Upload{} = upload, user_id) do
    with :ok <- validate_file_size(upload, :background, user_id),
         :ok <- validate_file_type(upload, @background_mime_types),
         :ok <- validate_file_extension(upload, @background_extensions) do
      validate_background_content(upload)
    end
  end

  defp validate_favicon_upload(%Plug.Upload{} = upload, user_id) do
    with :ok <- validate_file_size(upload, :favicon, user_id),
         :ok <- validate_file_type(upload, @favicon_mime_types) do
      validate_file_extension(upload, @favicon_extensions)
    end
  end

  defp validate_chat_attachment_upload(%Plug.Upload{} = upload, user_id) do
    with :ok <- validate_file_size(upload, :chat_attachment, user_id),
         :ok <- validate_file_type(upload, @chat_attachment_mime_types),
         :ok <- validate_file_extension(upload, @chat_attachment_extensions) do
      validate_attachment_content(upload)
    end
  end

  defp validate_file_size(%Plug.Upload{} = upload, type, user_id) do
    user = Accounts.get_user!(user_id)

    if user.is_admin do
      :ok
    else
      upload.path |> validate_size_against_limit(max_file_size_for_upload_type(type))
    end
  end

  defp max_file_size_for_upload_type(:background) do
    get_config(:max_background_size) || @default_max_background_size
  end

  defp max_file_size_for_upload_type(:chat_attachment) do
    @max_chat_attachment_size
  end

  defp max_file_size_for_upload_type(:favicon) do
    @max_favicon_size
  end

  defp max_file_size_for_upload_type(_) do
    get_config(:max_file_size) || @default_max_file_size
  end

  defp validate_size_against_limit(path, max_file_size) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > max_file_size ->
        {:error,
         {:file_too_large,
          "File size #{Float.round(size / (1024 * 1024), 2)}MB exceeds #{max_file_size / (1024 * 1024)}MB limit"}}

      {:ok, %File.Stat{size: 0}} ->
        {:error, {:empty_file, "File is empty"}}

      {:ok, %File.Stat{size: _size}} ->
        :ok

      {:error, reason} ->
        {:error, {:file_access_error, reason}}
    end
  end

  defp validate_file_type(%Plug.Upload{content_type: content_type}, allowed_types) do
    if content_type in allowed_types do
      :ok
    else
      {:error,
       {:invalid_file_type,
        "File type #{content_type} not allowed. Allowed types: #{Enum.join(allowed_types, ", ")}"}}
    end
  end

  defp validate_file_extension(%Plug.Upload{filename: filename}, allowed_extensions) do
    extension = filename |> Path.extname() |> String.downcase()

    if extension in allowed_extensions do
      :ok
    else
      {:error,
       {:invalid_extension,
        "File extension #{extension} not allowed. Allowed extensions: #{Enum.join(allowed_extensions, ", ")}"}}
    end
  end

  defp validate_avatar_content(%Plug.Upload{} = upload) do
    with {:ok, content} <- File.read(upload.path),
         :ok <- validate_magic_bytes(content, upload.content_type) do
      scan_for_malicious_content(content)
    end
  end

  defp validate_background_content(%Plug.Upload{} = upload) do
    with {:ok, content} <- File.read(upload.path),
         :ok <- validate_magic_bytes(content, upload.content_type) do
      scan_for_malicious_content(content)
    end
  end

  defp validate_attachment_content(%Plug.Upload{} = upload) do
    with {:ok, content} <- File.read(upload.path),
         :ok <- validate_magic_bytes(content, upload.content_type) do
      scan_for_malicious_content(content)
    end
  end

  defp validate_magic_bytes(content, content_type) do
    normalized_type =
      case content_type do
        "image/jpg" -> "image/jpeg"
        type -> type
      end

    case Map.get(@magic_bytes, normalized_type) do
      nil ->
        :ok

      expected_signatures ->
        matches =
          Enum.any?(expected_signatures, fn signature ->
            byte_size(content) >= byte_size(signature) and
              :binary.part(content, 0, byte_size(signature)) == signature
          end)

        if matches do
          :ok
        else
          {:error,
           {:invalid_file_format, "File content does not match declared type #{content_type}"}}
        end
    end
  end

  defp scan_for_malicious_content(content) do
    scan_content =
      if byte_size(content) > 1024 do
        :binary.part(content, 0, 1024)
      else
        content
      end

    content_str =
      case :unicode.characters_to_binary(scan_content, :latin1, :utf8) do
        result when is_binary(result) -> result
        _ -> scan_content
      end

    malicious_found =
      Enum.find(@malicious_patterns, fn pattern -> Regex.match?(pattern, content_str) end)

    case malicious_found do
      nil -> :ok
      _pattern -> {:error, {:malicious_content, "File contains potentially malicious content"}}
    end
  end

  defp upload_local(%Plug.Upload{} = upload, user_id, folder) do
    uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
    target_dir = Path.join(uploads_dir, folder)
    File.mkdir_p!(target_dir)
    safe_filename = sanitize_filename(upload.filename)
    filename = "#{user_id}_#{System.unique_integer([:positive])}_#{safe_filename}"
    filepath = Path.join(target_dir, filename)

    case File.cp(upload.path, filepath) do
      :ok -> {:ok, "/uploads/#{folder}/#{filename}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_s3(%Plug.Upload{} = upload, user_id, folder) do
    bucket = get_config(:bucket)
    _endpoint = get_config(:endpoint) || raise "R2_ENDPOINT not configured"
    safe_filename = sanitize_filename(upload.filename)
    filename = "#{user_id}_#{System.unique_integer([:positive])}_#{safe_filename}"
    key = "#{folder}/#{filename}"

    case File.read(upload.path) do
      {:ok, file_content} ->
        case ExAws.S3.put_object(bucket, key, file_content) |> ExAws.request() do
          {:ok, _response} -> {:ok, key}
          {:error, reason} -> {:error, "Upload failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  @doc "Deletes an avatar file from storage.\n\nTakes the full URL and extracts the necessary information to delete the file.\n"
  def delete_avatar(nil) do
    :ok
  end

  def delete_avatar("") do
    :ok
  end

  def delete_avatar(url) when is_binary(url) do
    result =
      case get_config(:adapter) do
        :local -> delete_local(url)
        :s3 -> delete_s3(url)
      end

    emit_upload_result(:delete_avatar, normalize_delete_result(result))
    result
  end

  @doc "Deletes a background file from storage.\n\nTakes the full URL and extracts the necessary information to delete the file.\n"
  def delete_background(nil) do
    :ok
  end

  def delete_background("") do
    :ok
  end

  def delete_background(url) when is_binary(url) do
    result =
      case get_config(:adapter) do
        :local -> delete_local(url)
        :s3 -> delete_s3(url)
      end

    emit_upload_result(:delete_background, normalize_delete_result(result))
    result
  end

  defp delete_local(url) do
    case String.split(url, "/") do
      [_, "uploads", folder, filename] when folder in ["avatars", "backgrounds"] ->
        uploads_dir = get_config(:uploads_dir) || "priv/static/uploads"
        filepath = Path.join([uploads_dir, folder, filename])
        File.rm(filepath)

      _ ->
        {:error, :invalid_url}
    end
  end

  defp delete_s3(url) do
    bucket = get_config(:bucket)

    case extract_s3_key_from_url(url) do
      {:ok, key} ->
        case ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
          {:ok, _response} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_s3_key_from_url(url) do
    uri = URI.parse(url)

    case uri.path do
      "/" <> path -> {:ok, path}
      _ -> {:error, :invalid_s3_url}
    end
  end

  @doc "Returns the public URL for an avatar.\n\nThe avatar value could be a filename or a full URL depending on storage adapter.\n"
  def avatar_url(nil) do
    nil
  end

  def avatar_url("") do
    nil
  end

  def avatar_url(avatar) when is_binary(avatar) do
    if String.starts_with?(avatar, "http") do
      avatar
    else
      avatar |> prefixed_key("avatars") |> public_storage_url()
    end
  end

  @doc "Returns the public URL for media attachments (timeline, chat, discussion).\n\nHandles S3 keys like \"timeline-attachments/user123/abc.jpg\" and converts them to full URLs.\n"
  def media_url(nil) do
    nil
  end

  def media_url("") do
    nil
  end

  def media_url(key) when is_binary(key) do
    if String.starts_with?(key, "http") do
      key
    else
      public_storage_url(key)
    end
  end

  @doc "Returns the public URL for a background.\n\nThe background value could be a filename or a full URL depending on storage adapter.\n"
  def background_url(nil) do
    nil
  end

  def background_url("") do
    nil
  end

  def background_url(background) when is_binary(background) do
    case get_config(:adapter) do
      :local -> local_upload_url(background, "backgrounds")
      :s3 -> remote_upload_url(background, "backgrounds")
    end
  end

  def favicon_url(nil) do
    nil
  end

  def favicon_url("") do
    nil
  end

  def favicon_url(favicon) when is_binary(favicon) do
    case get_config(:adapter) do
      :local -> local_upload_url(favicon, "favicons")
      :s3 -> remote_upload_url(favicon, "favicons")
    end
  end

  @doc "Returns the URL for a chat attachment.\nUses direct URL for public/group content, presigned URL for private DMs.\n\nThe attachment value could be a filename or a full URL depending on storage adapter.\n"
  def attachment_url(nil) do
    nil
  end

  def attachment_url("") do
    nil
  end

  def attachment_url(attachment, conversation \\ nil)

  def attachment_url(attachment, conversation) when is_binary(attachment) do
    is_private = conversation && conversation.type == "dm"

    if is_private do
      attachment_url_presigned(attachment)
    else
      attachment_url_direct(attachment)
    end
  end

  defp attachment_url_direct(attachment) when is_binary(attachment) do
    case get_config(:adapter) do
      :local -> local_attachment_url(attachment)
      :s3 -> remote_attachment_url(attachment)
    end
  end

  defp local_upload_url(value, folder) do
    if String.starts_with?(value, "/") do
      value
    else
      "/uploads/#{folder}/#{value}"
    end
  end

  defp remote_upload_url(value, prefix) do
    if String.starts_with?(value, "http") do
      value
    else
      value |> prefixed_key(prefix) |> public_storage_url()
    end
  end

  defp local_attachment_url(attachment) do
    if String.starts_with?(attachment, "/") do
      attachment
    else
      "/uploads/#{local_attachment_key(attachment)}"
    end
  end

  defp local_attachment_key(attachment) do
    if prefixed_attachment_key?(attachment) do
      attachment
    else
      "attachments/#{attachment}"
    end
  end

  defp prefixed_attachment_key?(attachment) do
    Enum.any?(
      [
        "chat-attachments/",
        "timeline-attachments/",
        "discussion-attachments/",
        "gallery-attachments/"
      ],
      &String.starts_with?(attachment, &1)
    )
  end

  defp remote_attachment_url(attachment) do
    if String.starts_with?(attachment, "http") do
      attachment
    else
      key =
        if String.contains?(attachment, "/") do
          attachment
        else
          "chat-attachments/#{attachment}"
        end

      public_storage_url(key)
    end
  end

  defp prefixed_key(value, prefix) do
    if String.starts_with?(value, "#{prefix}/") do
      value
    else
      "#{prefix}/#{value}"
    end
  end

  defp public_storage_url(key) do
    case get_config(:public_url) do
      nil ->
        bucket = get_config(:bucket) || raise "R2_BUCKET_NAME not configured"
        endpoint = get_config(:endpoint) || raise "R2_ENDPOINT not configured"
        "https://#{bucket}.#{endpoint}/#{key}"

      public_url ->
        "#{public_url}/#{key}"
    end
  end

  defp attachment_url_presigned(attachment) do
    if String.starts_with?(attachment, "http") do
      attachment
    else
      bucket = get_config(:bucket)
      config = ExAws.Config.new(:s3)

      key =
        if String.contains?(attachment, "/") do
          attachment
        else
          "chat-attachments/#{attachment}"
        end

      case ExAws.S3.presigned_url(config, :get, bucket, key,
             expires_in: 3600,
             virtual_host: false,
             query_params: [{"response-content-disposition", "inline"}]
           ) do
        {:ok, url} -> url
        _ -> attachment_url_direct(attachment)
      end
    end
  end

  defp crop_avatar_to_square(image_path) do
    output_path = image_path <> "_cropped.jpg"
    process_avatar_crop(image_path, output_path)
  rescue
    e -> final_avatar_crop_fallback(image_path, e)
  end

  defp process_avatar_crop(image_path, output_path) do
    if image_thumbnail_available?() do
      crop_avatar_with_image_lib(image_path, output_path)
    else
      copy_avatar_with_fallback(image_path, output_path)
    end
  end

  defp image_thumbnail_available? do
    Code.ensure_loaded?(Image) and function_exported?(Image, :thumbnail!, 3)
  end

  defp crop_avatar_with_image_lib(image_path, output_path) do
    thumb = Image.thumbnail!(image_path, 256, height: 256, crop: :center, resize: :both)
    Image.write!(thumb, output_path, suffix: ".jpg", quality: 90, strip_metadata: true)
    {:ok, output_path}
  rescue
    e ->
      Logger.warning("Image processing failed (#{Exception.message(e)}), using fallback")
      copy_avatar_with_fallback(image_path, output_path)
  end

  defp copy_avatar_with_fallback(source, destination) do
    case File.cp(source, destination) do
      :ok -> {:ok, destination}
      {:error, reason} -> {:error, "Failed to process avatar: #{inspect(reason)}"}
    end
  end

  defp final_avatar_crop_fallback(image_path, exception) do
    output_path = image_path <> "_cropped.jpg"

    case File.cp(image_path, output_path) do
      :ok -> {:ok, output_path}
      {:error, _reason} -> {:error, "Avatar cropping failed: #{Exception.message(exception)}"}
    end
  end

  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/, "")
    |> String.replace(~r/[<>:"|?*\\\/]/, "_")
    |> case do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      name -> name
    end
    |> String.slice(0, 100)
  end

  defp sanitize_filename(_) do
    "file"
  end

  defp strip_metadata_if_image(%Plug.Upload{content_type: content_type, path: path}) do
    if image_content_type?(content_type) do
      maybe_strip_image_metadata(path, content_type)
    else
      {:ok, path}
    end
  rescue
    _e -> {:ok, path}
  end

  defp image_content_type?(content_type) do
    value = content_type || ""
    String.starts_with?(value, "image/") and not String.contains?(value, "svg")
  end

  defp maybe_strip_image_metadata(path, content_type) do
    ext = extension_for_content_type(content_type)
    output_path = path <> "_stripped" <> ext

    if image_open_available?() do
      strip_with_image_lib(path, output_path, ext)
    else
      {:ok, path}
    end
  end

  defp extension_for_content_type("image/jpeg") do
    ".jpg"
  end

  defp extension_for_content_type("image/jpg") do
    ".jpg"
  end

  defp extension_for_content_type("image/png") do
    ".png"
  end

  defp extension_for_content_type("image/webp") do
    ".webp"
  end

  defp extension_for_content_type("image/gif") do
    ".gif"
  end

  defp extension_for_content_type(_) do
    ".jpg"
  end

  defp image_open_available? do
    Code.ensure_loaded?(Image) and function_exported?(Image, :open, 2)
  end

  defp strip_with_image_lib(path, output_path, ext) do
    img = Image.open!(path)
    Image.write!(img, output_path, suffix: ext, strip_metadata: true)
    {:ok, output_path}
  rescue
    _ -> {:ok, path}
  end

  defp get_config(key) do
    Application.get_env(:elektrine, :uploads, []) |> Keyword.get(key)
  end

  defp emit_upload_result(type, result) do
    metadata =
      case result do
        {:error, reason} -> %{reason: normalize_reason(reason)}
        _ -> %{}
      end

    outcome =
      case result do
        {:ok, _} -> :success
        _ -> :failure
      end

    Events.upload(type, outcome, result_size(result), metadata)
  end

  defp result_size({:ok, %{size: size}}) when is_integer(size) do
    size
  end

  defp result_size(_) do
    nil
  end

  defp normalize_reason(reason) when is_atom(reason) do
    reason
  end

  defp normalize_reason({reason, _}) when is_atom(reason) do
    reason
  end

  defp normalize_reason({reason, _, _}) when is_atom(reason) do
    reason
  end

  defp normalize_reason(reason) do
    inspect(reason)
  end

  defp normalize_delete_result(:ok) do
    {:ok, :deleted}
  end

  defp normalize_delete_result(error) do
    error
  end
end
