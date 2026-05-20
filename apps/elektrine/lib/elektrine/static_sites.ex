defmodule Elektrine.StaticSites do
  @moduledoc """
  Context for managing static site files.
  Handles uploading, storing, and serving user-uploaded static site content.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.User
  alias Elektrine.Profiles.StaticSiteDeployment
  alias Elektrine.Profiles.StaticSiteFile
  alias Elektrine.Profiles.UserProfile
  alias Elektrine.Repo

  require Logger

  # Up to 1000 files
  @max_files 1000
  # Maximum decompression ratio to prevent zip bombs (100:1)
  @max_decompression_ratio 100
  # Maximum size of a single file (10MB, aligned with StaticSiteFile changeset)
  @max_single_file_size 10_000_000
  # Maximum accepted zip upload and extracted payload size.
  @max_zip_archive_size 100 * 1024 * 1024
  @default_max_zip_uncompressed_size 100 * 1024 * 1024
  @auto_site_dirs ~w(dist build public out zig-out .)

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
    ".mjs" => "application/javascript",
    ".json" => "application/json",
    ".webmanifest" => "application/manifest+json",
    ".xml" => "application/xml",
    ".rss" => "application/rss+xml",
    ".atom" => "application/atom+xml",
    ".map" => "application/json",
    ".txt" => "text/plain",
    ".md" => "text/markdown",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".avif" => "image/avif",
    ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon",
    ".bmp" => "image/bmp",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf" => "font/ttf",
    ".otf" => "font/otf",
    ".eot" => "application/vnd.ms-fontobject",
    ".wasm" => "application/wasm",
    ".pdf" => "application/pdf",
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm"
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

  def get_static_site_deployment(user_id) do
    Repo.get_by(StaticSiteDeployment, user_id: user_id, provider: "github")
  end

  def get_static_site_deployment_by_github_repo(repo_owner, repo_name) do
    Repo.get_by(StaticSiteDeployment,
      provider: "github",
      repo_owner: normalize_repo_part(repo_owner),
      repo_name: normalize_repo_name(repo_name)
    )
    |> Repo.preload(:user)
  end

  def upsert_github_deployment(user_id, attrs) do
    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:provider, "github")

    case get_static_site_deployment(user_id) do
      nil ->
        %StaticSiteDeployment{}
        |> StaticSiteDeployment.changeset(attrs)
        |> Repo.insert()

      deployment ->
        deployment
        |> StaticSiteDeployment.changeset(attrs)
        |> Repo.update()
    end
  end

  def mark_deployment_deployed(%StaticSiteDeployment{} = deployment) do
    deployment
    |> StaticSiteDeployment.changeset(%{
      deploy_status: "deployed",
      last_deploy_error: nil,
      last_deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  def mark_deployment_queued(%StaticSiteDeployment{} = deployment) do
    update_deployment_status(deployment, "queued", nil)
  end

  def mark_deployment_deploying(%StaticSiteDeployment{} = deployment) do
    update_deployment_status(deployment, "deploying", nil)
  end

  def mark_deployment_failed(%StaticSiteDeployment{} = deployment, reason) do
    update_deployment_status(deployment, "failed", inspect(reason))
  end

  def update_deployment_webhook(%StaticSiteDeployment{} = deployment, webhook_id) do
    deployment
    |> StaticSiteDeployment.changeset(%{webhook_id: webhook_id})
    |> Repo.update()
  end

  def enqueue_github_deploy(%StaticSiteDeployment{} = deployment) do
    with {:ok, deployment} <- mark_deployment_queued(deployment) do
      %{deployment_id: deployment.id}
      |> Elektrine.StaticSites.GitHubDeployWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Uploads a static site file.
  """
  def upload_file(user, path, binary, _content_type) do
    size = byte_size(binary)

    with {:ok, path} <- normalize_site_path(path),
         :ok <- validate_limits(user.id, size),
         :ok <- validate_file_extension(path),
         content_type <- static_site_content_type(path),
         :ok <- validate_content_type(path, binary, content_type),
         storage_key <- generate_storage_key(user.id, path),
         :ok <- put_storage(storage_key, binary, content_type) do
      # Delete existing file at this path if any
      case get_file(user.id, path) do
        nil -> :ok
        existing -> delete_file_record(existing)
      end

      # Create new file record
      changeset =
        StaticSiteFile.changeset(%StaticSiteFile{}, %{
          user_id: user.id,
          path: path,
          storage_key: storage_key,
          content_type: content_type,
          size: size
        })

      case Repo.insert(changeset) do
        {:ok, file} ->
          {:ok, file}

        {:error, _changeset} = error ->
          delete_storage(storage_key)
          error
      end
    end
  end

  defp normalize_site_path(path) when is_binary(path) do
    decoded = URI.decode(path) |> String.trim()

    normalized =
      decoded
      |> String.replace("\\", "/")
      |> Path.expand("/")
      |> String.trim_leading("/")

    cond do
      decoded == "" ->
        {:error, :invalid_path}

      String.starts_with?(decoded, ["/", "\\"]) ->
        {:error, :invalid_path}

      String.contains?(decoded, ["..", "\0", "//", "\\"]) ->
        {:error, :invalid_path}

      normalized == "" ->
        {:error, :invalid_path}

      not Regex.match?(~r/^[A-Za-z0-9._\-\/]+$/, normalized) ->
        {:error, :invalid_path}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_site_path(_), do: {:error, :invalid_path}

  # Validates that the file extension is allowed
  defp validate_file_extension(path) do
    ext = Path.extname(path) |> String.downcase()

    if Map.has_key?(@allowed_extensions, ext) do
      :ok
    else
      {:error, :invalid_file_type}
    end
  end

  defp static_site_content_type(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&Map.fetch!(@allowed_extensions, &1))
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
        "application/manifest+json",
        "application/xml",
        "application/rss+xml",
        "application/atom+xml",
        "text/markdown",
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
      expected_mime in [
        "font/woff",
        "font/woff2",
        "font/ttf",
        "font/otf",
        "application/vnd.ms-fontobject",
        "application/wasm",
        "application/pdf",
        "image/avif",
        "image/bmp",
        "audio/mpeg",
        "audio/wav",
        "audio/ogg",
        "video/mp4",
        "video/webm"
      ] ->
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

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, binary),
             # Store content type in a sidecar file for local storage
             :ok <- File.write(path <> ".meta", content_type) do
          :ok
        else
          {:error, reason} -> {:error, {:upload_failed, reason}}
        end

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

  defp normalize_repo_part(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_repo_part(value), do: value

  defp normalize_repo_name(value) when is_binary(value),
    do: value |> normalize_repo_part() |> String.replace_suffix(".git", "")

  defp normalize_repo_name(value), do: value

  @doc """
  Uploads multiple files from a zip archive.
  """
  def upload_zip(user, zip_binary) do
    with {:ok, entries} <- preflight_zip(user.id, zip_binary),
         :ok <- validate_zip_limits(user.id, entries) do
      upload_zip_entries(user, zip_binary, entries)
    end
  end

  @doc """
  Replaces a user's static site with files from a zip archive.

  The archive is preflighted before existing files are deleted, so invalid zips
  do not clear the currently published site.
  """
  def replace_with_zip(user, zip_binary) do
    with {:ok, entries} <- preflight_zip(user.id, zip_binary),
         :ok <- validate_zip_limits(user.id, entries),
         {_count, nil} <- delete_all_files(user.id) do
      upload_zip_entries(user, zip_binary, entries)
    else
      {_count, error} when not is_nil(error) -> {:error, error}
      error -> error
    end
  end

  @doc """
  Replaces a user's static site with a selected folder from a GitHub archive zip.
  """
  def replace_with_repo_archive(user, zip_binary, site_dir \\ "auto") do
    with {:ok, site_zip_binary} <- repo_archive_site_zip(zip_binary, site_dir) do
      replace_with_zip(user, site_zip_binary)
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
    storage_limit = user_storage_limit(user_id)

    cond do
      current_usage + new_file_size > storage_limit ->
        {:error, :storage_limit_exceeded}

      current_count >= @max_files ->
        {:error, :file_limit_exceeded}

      true ->
        :ok
    end
  end

  defp update_deployment_status(%StaticSiteDeployment{} = deployment, status, error) do
    deployment
    |> StaticSiteDeployment.changeset(%{deploy_status: status, last_deploy_error: error})
    |> Repo.update()
  end

  defp repo_archive_site_zip(zip_binary, site_dir) do
    case :zip.zip_open(zip_binary, [:memory]) do
      {:ok, handle} ->
        try do
          with {:ok, file_list} <- :zip.zip_list_dir(handle),
               zip_entries <- zip_file_entries(file_list),
               {:ok, entries} <- repo_archive_entries(zip_entries),
               {:ok, prefix} <- resolve_site_dir(entries, site_dir),
               {:ok, files} <- repo_archive_site_files(handle, entries, prefix) do
            create_site_zip(files)
          else
            {:error, reason} -> {:error, reason}
            {:zip_error, reason} -> {:error, reason}
          end
        after
          :zip.zip_close(handle)
        end

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  defp repo_archive_entries(zip_entries) do
    with {:ok, entries} <- collect_zip_entries(zip_entries),
         normalized <- normalize_repo_archive_entries(entries),
         :ok <- validate_zip_entry_count(normalized) do
      {:ok, normalized}
    end
  end

  defp normalize_repo_archive_entries(entries) do
    all_files = Enum.map(entries, &{&1.raw_path, ""})

    Enum.map(entries, fn entry ->
      Map.put(entry, :repo_path, normalize_zip_path(entry.raw_path, all_files))
    end)
  end

  defp resolve_site_dir(entries, site_dir) do
    paths = MapSet.new(Enum.map(entries, & &1.repo_path))

    site_dir
    |> normalize_repo_site_dir()
    |> candidate_site_dirs()
    |> Enum.find(&site_dir_has_index?(paths, &1))
    |> case do
      nil -> {:error, :site_dir_not_found}
      prefix -> {:ok, prefix}
    end
  end

  defp normalize_repo_site_dir(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> "auto"
      String.downcase(value) == "auto" -> "auto"
      String.starts_with?(value, ["/", "\\"]) -> "auto"
      String.contains?(value, ["..", "\0", "\\"]) -> "auto"
      true -> String.trim(value, "/")
    end
  end

  defp normalize_repo_site_dir(_value), do: "auto"

  defp candidate_site_dirs("auto"), do: @auto_site_dirs
  defp candidate_site_dirs(site_dir), do: [site_dir]

  defp site_dir_has_index?(paths, "."), do: MapSet.member?(paths, "index.html")

  defp site_dir_has_index?(paths, site_dir) do
    MapSet.member?(paths, site_dir <> "/index.html")
  end

  defp repo_archive_site_files(handle, entries, prefix) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, files} ->
      case repo_archive_site_path(entry.repo_path, prefix) do
        nil ->
          {:cont, {:ok, files}}

        path ->
          with {:ok, content} <- zip_entry_content(handle, entry),
               {:ok, path} <- normalize_site_path(path),
               :ok <- validate_file_extension(path) do
            {:cont, {:ok, [{String.to_charlist(path), content} | files]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, []} -> {:error, :site_dir_not_found}
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_archive_site_path(path, "."), do: path

  defp repo_archive_site_path(path, prefix) do
    prefix = prefix <> "/"

    if String.starts_with?(path, prefix) do
      String.replace_prefix(path, prefix, "")
    end
  end

  defp create_site_zip(files) do
    case :zip.create(~c"site.zip", files, [:memory]) do
      {:ok, {_name, zip_binary}} -> {:ok, zip_binary}
      {:error, reason} -> {:error, {:invalid_zip, reason}}
    end
  end

  defp validate_zip_limits(user_id, entries) do
    total_size = Enum.reduce(entries, 0, fn entry, acc -> acc + entry.size end)
    new_file_count = length(entries)
    current_file_count = file_count(user_id)
    current_usage = total_storage_used(user_id)
    storage_limit = user_storage_limit(user_id)

    cond do
      total_size > max_zip_uncompressed_size() ->
        {:error, :storage_limit_exceeded}

      current_usage + total_size > storage_limit ->
        {:error, :storage_limit_exceeded}

      current_file_count + new_file_count > @max_files ->
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

  defp preflight_zip(user_id, zip_binary) do
    zip_size = byte_size(zip_binary)
    storage_limit = user_storage_limit(user_id)

    if zip_size > @max_zip_archive_size do
      Logger.warning("Zip archive too large: #{zip_size} bytes exceeds limit")
      {:error, :storage_limit_exceeded}
    else
      do_preflight_zip(user_id, zip_binary, zip_size, storage_limit)
    end
  end

  defp do_preflight_zip(_user_id, zip_binary, zip_size, storage_limit) do
    case :zip.zip_open(zip_binary, [:memory]) do
      {:ok, handle} ->
        try do
          with {:ok, file_list} <- :zip.zip_list_dir(handle),
               zip_entries <- zip_file_entries(file_list),
               :ok <- validate_zip_entry_count(zip_entries),
               {:ok, entries} <- build_zip_entries(zip_entries),
               :ok <- validate_zip_uncompressed_size(entries, zip_size, storage_limit) do
            {:ok, entries}
          else
            {:error, reason} -> {:error, {:invalid_zip, reason}}
            {:zip_error, reason} -> {:error, reason}
          end
        after
          :zip.zip_close(handle)
        end

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  defp zip_file_entries(file_list) do
    Enum.filter(file_list, fn
      {:zip_file, _, _, _, _, _} -> true
      _ -> false
    end)
  end

  defp validate_zip_entry_count(zip_entries) do
    if length(zip_entries) > @max_files do
      Logger.warning("Zip contains too many entries: #{length(zip_entries)}")
      {:zip_error, :file_limit_exceeded}
    else
      :ok
    end
  end

  defp build_zip_entries(zip_entries) do
    with {:ok, entries} <- collect_zip_entries(zip_entries) do
      normalize_zip_entries(entries)
    end
  end

  defp collect_zip_entries(zip_entries) do
    zip_entries
    |> Enum.reduce_while({:ok, []}, fn {:zip_file, zip_name, file_info, _comment, _offset,
                                        _comp_size},
                                       {:ok, entries} ->
      with {:ok, raw_path} <- zip_entry_name(zip_name),
           {:ok, entry} <- zip_entry(zip_name, raw_path, file_info) do
        case entry do
          :skip -> {:cont, {:ok, entries}}
          entry -> {:cont, {:ok, [entry | entries]}}
        end
      else
        {:error, reason} -> {:halt, {:zip_error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:zip_error, reason} -> {:zip_error, reason}
    end
  end

  defp zip_entry(zip_name, raw_path, file_info) do
    type = zip_entry_type(file_info)

    cond do
      skippable_zip_path?(raw_path) or zip_entry_directory?(raw_path, type) ->
        {:ok, :skip}

      type != :regular ->
        {:error, :invalid_zip_entry}

      true ->
        case zip_entry_size(file_info) do
          size when is_integer(size) and size >= 0 and size <= @max_single_file_size ->
            {:ok, %{zip_name: zip_name, raw_path: raw_path, size: size}}

          size when is_integer(size) and size > @max_single_file_size ->
            {:error, :file_too_large}

          _ ->
            {:error, :invalid_zip_entry}
        end
    end
  end

  defp zip_entry_name(name) when is_binary(name), do: {:ok, name}

  defp zip_entry_name(name) when is_list(name) do
    {:ok, List.to_string(name)}
  rescue
    _ -> {:error, :invalid_path}
  end

  defp zip_entry_name(_name), do: {:error, :invalid_path}

  defp zip_entry_size(
         {:file_info, size, _type, _access, _atime, _mtime, _ctime, _mode, _links, _major_device,
          _minor_device, _inode, _uid, _gid}
       ),
       do: size

  defp zip_entry_size(_file_info), do: :unknown

  defp zip_entry_type(
         {:file_info, _size, type, _access, _atime, _mtime, _ctime, _mode, _links, _major_device,
          _minor_device, _inode, _uid, _gid}
       ),
       do: type

  defp zip_entry_type(_file_info), do: :unknown

  defp zip_entry_directory?(path, type), do: type == :directory or String.ends_with?(path, "/")

  defp skippable_zip_path?(path) do
    String.contains?(path, "__MACOSX") or String.starts_with?(Path.basename(path), ".")
  end

  defp normalize_zip_entries([]), do: {:ok, []}

  defp normalize_zip_entries(entries) do
    all_files = Enum.map(entries, &{&1.raw_path, ""})

    entries
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry,
                                                     {:ok, normalized_entries, seen_paths} ->
      raw_path = normalize_zip_path(entry.raw_path, all_files)

      with {:ok, path} <- normalize_site_path(raw_path),
           :ok <- validate_file_extension(path),
           :ok <- validate_unique_zip_path(path, seen_paths) do
        {:cont,
         {:ok, [Map.put(entry, :path, path) | normalized_entries], MapSet.put(seen_paths, path)}}
      else
        {:error, reason} -> {:halt, {:zip_error, reason}}
      end
    end)
    |> case do
      {:ok, entries, _seen_paths} -> {:ok, Enum.reverse(entries)}
      {:zip_error, reason} -> {:zip_error, reason}
    end
  end

  defp validate_unique_zip_path(path, seen_paths) do
    if MapSet.member?(seen_paths, path) do
      {:error, :duplicate_zip_path}
    else
      :ok
    end
  end

  defp validate_zip_uncompressed_size(entries, zip_size, storage_limit) do
    total_uncompressed = Enum.reduce(entries, 0, fn entry, acc -> acc + entry.size end)
    hard_limit = min(storage_limit, max_zip_uncompressed_size())
    decompression_ratio = if zip_size > 0, do: total_uncompressed / zip_size, else: 0

    cond do
      total_uncompressed > hard_limit ->
        Logger.warning("Zip too large: #{total_uncompressed} bytes exceeds limit")
        {:zip_error, :storage_limit_exceeded}

      decompression_ratio > @max_decompression_ratio ->
        Logger.warning("Zip bomb detected: ratio #{decompression_ratio}:1 exceeds limit")
        {:zip_error, :zip_bomb_detected}

      true ->
        :ok
    end
  end

  defp upload_zip_entries(user, zip_binary, entries) do
    case :zip.zip_open(zip_binary, [:memory]) do
      {:ok, handle} ->
        try do
          case extract_and_upload_zip_entries(handle, user, entries) do
            {:ok, results} ->
              errors = Enum.filter(results, &match?({:error, _}, &1))

              if Enum.empty?(errors) do
                {:ok, length(results)}
              else
                {:error, :partial_upload, errors}
              end

            {:error, reason} ->
              {:error, reason}
          end
        after
          :zip.zip_close(handle)
        end

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  defp extract_and_upload_zip_entries(handle, user, entries) do
    entries
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, results, extracted_size} ->
      with {:ok, content} <- zip_entry_content(handle, entry),
           new_extracted_size <- extracted_size + byte_size(content),
           :ok <- validate_extracted_zip_size(new_extracted_size) do
        content_type = static_site_content_type(entry.path)
        result = upload_file(user, entry.path, content, content_type)
        {:cont, {:ok, [result | results], new_extracted_size}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results, _extracted_size} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp zip_entry_content(handle, entry) do
    case :zip.zip_get(entry.zip_name, handle) do
      {:ok, {_name, content}} when is_binary(content) ->
        cond do
          byte_size(content) != entry.size ->
            {:error, {:invalid_zip, :size_mismatch}}

          byte_size(content) > @max_single_file_size ->
            {:error, :file_too_large}

          true ->
            {:ok, content}
        end

      {:ok, _unexpected} ->
        {:error, {:invalid_zip, :invalid_entry}}

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  defp validate_extracted_zip_size(size) do
    if size > max_zip_uncompressed_size() do
      {:error, :storage_limit_exceeded}
    else
      :ok
    end
  end

  defp max_zip_uncompressed_size do
    config = Application.get_env(:elektrine, :static_sites, []) || []

    case Keyword.get(config, :max_zip_uncompressed_size) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_max_zip_uncompressed_size
    end
  end

  defp user_storage_limit(user_id) do
    case Repo.get(User, user_id) do
      %User{storage_limit_bytes: limit} when is_integer(limit) and limit > 0 -> limit
      _ -> default_storage_limit()
    end
  end

  defp default_storage_limit, do: 524_288_000

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
