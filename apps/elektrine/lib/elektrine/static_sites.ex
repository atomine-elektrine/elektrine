defmodule Elektrine.StaticSites do
  @moduledoc """
  Context for managing static site files.
  Handles uploading, storing, and serving user-uploaded static site content.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Profiles.StaticSiteFile
  alias Elektrine.Profiles.UserProfile
  alias Elektrine.Repo

  require Logger

  # 1GB total storage per user
  @max_total_size 1_000_000_000
  # Up to 1000 files
  @max_files 1000
  # Maximum decompression ratio to prevent zip bombs (100:1)
  @max_decompression_ratio 100
  # Maximum size of a single file (50MB)
  @max_single_file_size 50_000_000

  # Magic bytes for content type validation
  @magic_bytes %{
    # Images
    "image/png" => <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>,
    "image/jpeg" => <<0xFF, 0xD8, 0xFF>>,
    "image/gif" => <<"GIF">>,
    "image/webp" => <<"RIFF">>
    # Note: SVG and text files validated differently (as text)
  }

  # Allowed file extensions and their expected MIME types
  @allowed_extensions %{
    ".html" => "text/html",
    ".htm" => "text/html",
    ".css" => "text/css",
    ".js" => "application/javascript",
    ".json" => "application/json",
    ".txt" => "text/plain",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf" => "font/ttf",
    ".otf" => "font/otf"
  }

  @doc """
  Gets a static site file by user_id and path.
  """
  def get_file(user_id, path) do
    Repo.get_by(StaticSiteFile, user_id: user_id, path: path)
  end

  @doc """
  Gets all static site files for a user.
  """
  def list_files(user_id) do
    StaticSiteFile
    |> where([f], f.user_id == ^user_id)
    |> order_by([f], asc: f.path)
    |> Repo.all()
  end

  @doc """
  Gets total storage used by a user's static site.
  """
  def total_storage_used(user_id) do
    StaticSiteFile
    |> where([f], f.user_id == ^user_id)
    |> select([f], sum(f.size))
    |> Repo.one() || 0
  end

  @doc """
  Gets file count for a user's static site.
  """
  def file_count(user_id) do
    StaticSiteFile
    |> where([f], f.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Uploads a static site file.
  """
  def upload_file(user, path, binary, content_type) do
    size = byte_size(binary)

    with :ok <- validate_limits(user.id, size),
         :ok <- validate_file_extension(path),
         :ok <- validate_content_type(path, binary, content_type),
         storage_key <- generate_storage_key(user.id, path),
         :ok <- put_storage(storage_key, binary, content_type) do
      # Delete existing file at this path if any
      case get_file(user.id, path) do
        nil -> :ok
        existing -> delete_file_record(existing)
      end

      # Create new file record
      %StaticSiteFile{}
      |> StaticSiteFile.changeset(%{
        user_id: user.id,
        path: path,
        storage_key: storage_key,
        content_type: content_type,
        size: size
      })
      |> Repo.insert()
    end
  end

  # Validates that the file extension is allowed
  defp validate_file_extension(path) do
    ext = Path.extname(path) |> String.downcase()

    if Map.has_key?(@allowed_extensions, ext) do
      :ok
    else
      {:error, :invalid_file_type}
    end
  end

  # Validates that the content matches the declared MIME type
  defp validate_content_type(path, binary, _declared_content_type) do
    ext = Path.extname(path) |> String.downcase()
    expected_mime = Map.get(@allowed_extensions, ext)

    cond do
      # Text-based files - verify they're valid UTF-8 text
      expected_mime in [
        "text/html",
        "text/css",
        "application/javascript",
        "application/json",
        "text/plain"
      ] ->
        if String.valid?(binary) or valid_utf8_with_bom?(binary) do
          :ok
        else
          Logger.warning("Static site upload rejected: #{path} - invalid text encoding")
          {:error, :invalid_content}
        end

      # SVG - must be valid XML text
      expected_mime == "image/svg+xml" ->
        if String.valid?(binary) and String.contains?(binary, "<svg") do
          :ok
        else
          Logger.warning("Static site upload rejected: #{path} - invalid SVG content")
          {:error, :invalid_content}
        end

      # Binary files with magic bytes
      Map.has_key?(@magic_bytes, expected_mime) ->
        expected_magic = Map.get(@magic_bytes, expected_mime)

        if binary_part_safe(binary, 0, byte_size(expected_magic)) == expected_magic do
          :ok
        else
          Logger.warning(
            "Static site upload rejected: #{path} - magic bytes mismatch for #{expected_mime}"
          )

          {:error, :invalid_content}
        end

      # ICO files - check for valid ICO header
      expected_mime == "image/x-icon" ->
        if byte_size(binary) >= 4 and
             binary_part_safe(binary, 0, 4) in [<<0, 0, 1, 0>>, <<0, 0, 2, 0>>] do
          :ok
        else
          Logger.warning("Static site upload rejected: #{path} - invalid ICO header")
          {:error, :invalid_content}
        end

      # Font files - basic validation (non-empty binary)
      expected_mime in ["font/woff", "font/woff2", "font/ttf", "font/otf"] ->
        if byte_size(binary) > 0 do
          :ok
        else
          {:error, :invalid_content}
        end

      true ->
        {:error, :invalid_file_type}
    end
  end

  defp valid_utf8_with_bom?(binary) do
    # Check for UTF-8 BOM and strip it
    case binary do
      <<0xEF, 0xBB, 0xBF, rest::binary>> -> String.valid?(rest)
      _ -> false
    end
  end

  defp binary_part_safe(binary, start, length) do
    if byte_size(binary) >= start + length do
      binary_part(binary, start, length)
    else
      <<>>
    end
  end

  defp put_storage(key, binary, content_type) do
    case get_storage_config() do
      {:local, dir} ->
        path = Path.join(dir, key)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, binary)
        # Store content type in a sidecar file for local storage
        File.write!(path <> ".meta", content_type)
        :ok

      {:s3, bucket} ->
        case ExAws.S3.put_object(bucket, key, binary, content_type: content_type)
             |> ExAws.request() do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:upload_failed, reason}}
        end
    end
  end

  defp get_storage(key) do
    case get_storage_config() do
      {:local, dir} ->
        path = Path.join(dir, key)

        if File.exists?(path) do
          {:ok, File.read!(path)}
        else
          {:error, :not_found}
        end

      {:s3, bucket} ->
        case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
          {:ok, %{body: body}} -> {:ok, body}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp delete_storage(key) do
    case get_storage_config() do
      {:local, dir} ->
        path = Path.join(dir, key)
        File.rm(path)
        File.rm(path <> ".meta")
        :ok

      {:s3, bucket} ->
        ExAws.S3.delete_object(bucket, key) |> ExAws.request()
        :ok
    end
  end

  defp get_storage_config do
    config = Application.get_env(:elektrine, :uploads, [])

    case Keyword.get(config, :adapter) do
      :local -> {:local, Keyword.get(config, :uploads_dir, "tmp/uploads")}
      _ -> {:s3, Keyword.get(config, :bucket)}
    end
  end

  @doc """
  Uploads multiple files from a zip archive.
  """
  def upload_zip(user, zip_binary) do
    with {:ok, files} <- extract_zip(zip_binary),
         :ok <- validate_zip_limits(user.id, files) do
      results =
        Enum.map(files, fn {path, content} ->
          content_type = MIME.from_path(path)
          upload_file(user, path, content, content_type)
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if Enum.empty?(errors) do
        {:ok, length(results)}
      else
        {:error, :partial_upload, errors}
      end
    end
  end

  @doc """
  Deletes a static site file.
  """
  def delete_file(user_id, path) do
    case get_file(user_id, path) do
      nil ->
        {:error, :not_found}

      file ->
        delete_storage(file.storage_key)
        Repo.delete(file)
    end
  end

  @doc """
  Deletes all static site files for a user.
  """
  def delete_all_files(user_id) do
    files = list_files(user_id)

    Enum.each(files, fn file ->
      delete_storage(file.storage_key)
    end)

    StaticSiteFile
    |> where([f], f.user_id == ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Gets file content for serving.
  """
  def get_file_content(file) do
    get_storage(file.storage_key)
  end

  @doc """
  Sets the profile to static mode.
  """
  def enable_static_mode(user_id) do
    case Repo.get_by(UserProfile, user_id: user_id) do
      nil ->
        {:error, :profile_not_found}

      profile ->
        profile
        |> Ecto.Changeset.change(profile_mode: "static")
        |> Repo.update()
    end
  end

  @doc """
  Sets the profile to builder mode.
  """
  def enable_builder_mode(user_id) do
    case Repo.get_by(UserProfile, user_id: user_id) do
      nil ->
        {:error, :profile_not_found}

      profile ->
        profile
        |> Ecto.Changeset.change(profile_mode: "builder")
        |> Repo.update()
    end
  end

  # Private functions

  defp validate_limits(user_id, new_file_size) do
    current_usage = total_storage_used(user_id)
    current_count = file_count(user_id)

    cond do
      current_usage + new_file_size > @max_total_size ->
        {:error, :storage_limit_exceeded}

      current_count >= @max_files ->
        {:error, :file_limit_exceeded}

      true ->
        :ok
    end
  end

  defp validate_zip_limits(user_id, files) do
    total_size = Enum.reduce(files, 0, fn {_path, content}, acc -> acc + byte_size(content) end)
    file_count = length(files)
    current_usage = total_storage_used(user_id)

    cond do
      current_usage + total_size > @max_total_size ->
        {:error, :storage_limit_exceeded}

      file_count > @max_files ->
        {:error, :file_limit_exceeded}

      true ->
        :ok
    end
  end

  defp generate_storage_key(user_id, path) do
    # Use cryptographically secure random bytes instead of timestamp
    random_bytes = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(random_bytes, case: :lower)
    # Sanitize filename to prevent path traversal in S3
    safe_filename = Path.basename(path) |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
    "static_sites/#{user_id}/#{hex}/#{safe_filename}"
  end

  defp extract_zip(zip_binary) do
    zip_size = byte_size(zip_binary)

    # First, check zip structure without extracting to detect zip bombs
    # OTP 28+: Use zip_open with :memory option, then zip_list_dir
    case :zip.zip_open(zip_binary, [:memory]) do
      {:ok, handle} ->
        try do
          case :zip.zip_list_dir(handle) do
            {:ok, file_list} ->
              # Calculate total uncompressed size from file list
              # file_list contains {:zip_comment, _} and {:zip_file, Name, FileInfo, Comment, Offset, CompSize}
              total_uncompressed =
                file_list
                |> Enum.filter(fn
                  {:zip_file, _, _, _, _, _} -> true
                  _ -> false
                end)
                |> Enum.reduce(0, fn {:zip_file, _name, file_info, _comment, _offset, _comp_size},
                                     acc ->
                  # file_info is a :file_info record - size is the first field (index 1 after record tag)
                  uncompressed_size = elem(file_info, 1)
                  acc + uncompressed_size
                end)

              # Check decompression ratio to prevent zip bombs
              decompression_ratio = if zip_size > 0, do: total_uncompressed / zip_size, else: 0

              cond do
                decompression_ratio > @max_decompression_ratio ->
                  Logger.warning(
                    "Zip bomb detected: ratio #{decompression_ratio}:1 exceeds limit"
                  )

                  {:error, :zip_bomb_detected}

                total_uncompressed > @max_total_size ->
                  Logger.warning("Zip too large: #{total_uncompressed} bytes exceeds limit")
                  {:error, :storage_limit_exceeded}

                true ->
                  # Safe to extract
                  extract_zip_contents(zip_binary)
              end

            {:error, reason} ->
              {:error, {:invalid_zip, reason}}
          end
        after
          :zip.zip_close(handle)
        end

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  defp extract_zip_contents(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, files} ->
        # Filter out macOS metadata and directories
        files =
          files
          |> Enum.map(fn {path, content} -> {to_string(path), content} end)
          |> Enum.reject(fn {path, _content} ->
            # Skip macOS metadata, directories, and hidden files
            String.contains?(path, "__MACOSX") or
              String.ends_with?(path, "/") or
              String.starts_with?(Path.basename(path), ".")
          end)

        # Normalize paths (strip common prefix)
        files =
          files
          |> Enum.map(fn {path, content} ->
            normalized = normalize_zip_path(path, files)
            {normalized, content}
          end)
          |> Enum.filter(fn {path, content} ->
            # Skip empty paths, files that are too large, and paths with traversal sequences
            path != "" and
              byte_size(content) <= @max_single_file_size and
              not String.contains?(path, ["../", "..\\", "/..", "\\.."]) and
              not String.starts_with?(path, ["../", "..\\", "/", "\\"]) and
              not String.contains?(path, "\0")
          end)

        {:ok, files}

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  defp normalize_zip_path(path, all_files) do
    # If all files share a common root directory, strip it
    paths = Enum.map(all_files, fn {p, _} -> to_string(p) end)

    case find_common_prefix(paths) do
      nil ->
        path

      prefix ->
        String.replace_prefix(path, prefix, "")
    end
  end

  defp find_common_prefix(paths) do
    # Check if all paths start with the same directory
    case Enum.map(paths, &String.split(&1, "/", parts: 2)) do
      [[first | _] | rest] when first != "" ->
        if Enum.all?(rest, fn
             [^first | _] -> true
             _ -> false
           end) do
          first <> "/"
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp delete_file_record(file) do
    delete_storage(file.storage_key)
    Repo.delete(file)
  end
end
