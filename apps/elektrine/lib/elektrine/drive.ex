defmodule Elektrine.Drive do
  @moduledoc """
  Personal drive library with folders, share links, and DAV-friendly operations.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.Storage
  alias Elektrine.Accounts.User
  alias Elektrine.Drive.{FileShare, StoredFile, StoredFolder}
  alias Elektrine.Repo
  alias ExAws.S3

  @default_max_upload_size 100 * 1024 * 1024
  @share_expiry_options [
    {"1 day", "1d"},
    {"7 days", "7d"},
    {"30 days", "30d"},
    {"Never", "never"}
  ]
  @share_access_options [
    {"Download", "download"},
    {"View inline", "view"}
  ]
  @sort_options [
    {"Newest", "updated_desc"},
    {"Oldest", "updated_asc"},
    {"Name A-Z", "name_asc"},
    {"Name Z-A", "name_desc"},
    {"Location A-Z", "path_asc"},
    {"Location Z-A", "path_desc"},
    {"Largest", "size_desc"},
    {"Smallest", "size_asc"}
  ]
  @quick_filter_options [
    {"All", "all"},
    {"Recent", "recent"},
    {"Images", "images"},
    {"Docs", "documents"},
    {"Media", "media"},
    {"Shared", "shared"}
  ]
  @valid_share_access_levels Enum.map(@share_access_options, &elem(&1, 1))
  @valid_sort_values Enum.map(@sort_options, &elem(&1, 1))
  @valid_filter_values Enum.map(@quick_filter_options, &elem(&1, 1))

  def max_upload_size, do: @default_max_upload_size
  def share_expiry_options, do: @share_expiry_options
  def share_access_options, do: @share_access_options
  def sort_options, do: @sort_options
  def quick_filter_options, do: @quick_filter_options

  def list_files(user_id) do
    StoredFile
    |> where([f], f.user_id == ^user_id)
    |> order_by([f], asc: f.path)
    |> preload(shares: ^active_shares_query())
    |> Repo.all()
  end

  def list_folders(user_id) do
    StoredFolder
    |> where([f], f.user_id == ^user_id)
    |> order_by([f], asc: f.path)
    |> Repo.all()
  end

  def list_folder(user_id, folder_path \\ "", opts \\ %{}) do
    with {:ok, normalized_folder} <- normalize_folder(folder_path) do
      normalized_opts = normalize_list_opts(opts)
      files = list_files(user_id)
      folders = list_folders(user_id)

      {:ok,
       %{
         current_folder: normalized_folder,
         breadcrumbs: breadcrumbs(normalized_folder),
         folders: filtered_folder_entries(folders, files, normalized_folder, normalized_opts),
         files:
           files_in_folder(files, normalized_folder)
           |> apply_file_filter(normalized_opts.filter)
           |> filter_files(normalized_opts.search)
           |> sort_files(normalized_opts.sort),
         search_query: normalized_opts.search,
         sort_by: normalized_opts.sort,
         filter_by: normalized_opts.filter
       }}
    end
  end

  def get_file(user_id, file_id) do
    Repo.get_by(StoredFile, id: file_id, user_id: user_id)
  end

  def get_file_by_path(user_id, path) when is_binary(path) do
    case normalize_file_path(path) do
      {:ok, normalized_path} -> Repo.get_by(StoredFile, user_id: user_id, path: normalized_path)
      _ -> nil
    end
  end

  def normalize_folder(folder_path), do: normalize_folder_path(folder_path)

  def create_folder(user_id, path) do
    with {:ok, normalized_path} <- normalize_folder(path),
         false <- normalized_path == "",
         false <- file_exists?(user_id, normalized_path) do
      Repo.transaction(fn ->
        ensure_folder_hierarchy!(user_id, normalized_path)
        Repo.get_by!(StoredFolder, user_id: user_id, path: normalized_path)
      end)
      |> normalize_transaction_result()
    else
      true -> {:error, :invalid_folder_path}
      {:error, reason} -> {:error, reason}
    end
  end

  def upload_file(%User{} = user, folder_path, %Plug.Upload{} = upload) do
    with {:ok, normalized_path} <- build_visible_path(folder_path, upload.filename),
         {:ok, binary} <- File.read(upload.path),
         content_type <- normalize_content_type(upload.content_type, upload.filename) do
      put_file_content(user, normalized_path, binary,
        filename: upload.filename,
        content_type: content_type
      )
    end
  end

  def put_file_content(%User{} = user, path, binary, opts \\ %{}) when is_binary(binary) do
    opts = if Keyword.keyword?(opts), do: Map.new(opts), else: opts

    with {:ok, normalized_path} <- normalize_file_path(path),
         :ok <- validate_file_size(byte_size(binary)),
         existing_file <- Repo.get_by(StoredFile, user_id: user.id, path: normalized_path),
         :ok <- validate_storage_limit(user, existing_file, byte_size(binary)),
         :ok <- ensure_parent_folder_hierarchy(user.id, normalized_path),
         filename <- Map.get(opts, :filename) || file_name_from_path(normalized_path),
         content_type <- normalize_content_type(Map.get(opts, :content_type), filename),
         {:ok, storage_key} <- put_storage_binary(user.id, binary, filename, content_type) do
      attrs = %{
        user_id: user.id,
        path: normalized_path,
        storage_key: storage_key,
        original_filename: file_name_from_path(normalized_path),
        content_type: content_type,
        size: byte_size(binary)
      }

      case persist_file(existing_file, attrs) do
        {:ok, file, old_storage_key} ->
          maybe_delete_storage(old_storage_key)
          Storage.update_user_storage(user.id)
          {:ok, Repo.preload(file, :shares)}

        {:error, reason} ->
          maybe_delete_storage(storage_key)
          {:error, reason}
      end
    end
  end

  def rename_file(user_id, file_id, new_name) do
    with %StoredFile{} = file <- get_file(user_id, file_id),
         {:ok, normalized_name} <- normalize_filename(new_name),
         new_path <- join_path(parent_folder(file.path), normalized_name),
         :ok <- ensure_target_file_path_available(user_id, new_path, file.id),
         {:ok, updated} <-
           file
           |> StoredFile.changeset(%{path: new_path, original_filename: normalized_name})
           |> Repo.update() do
      {:ok, Repo.preload(updated, :shares)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def move_file(user_id, file_id, folder_path) do
    with %StoredFile{} = file <- get_file(user_id, file_id),
         {:ok, normalized_folder} <- normalize_folder(folder_path),
         :ok <- ensure_folder_hierarchy(user_id, normalized_folder),
         new_path <- join_path(normalized_folder, file_name_from_path(file.path)),
         :ok <- ensure_target_file_path_available(user_id, new_path, file.id),
         {:ok, updated} <- file |> StoredFile.changeset(%{path: new_path}) |> Repo.update() do
      {:ok, Repo.preload(updated, :shares)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_file(user_id, file_id) do
    case get_file(user_id, file_id) do
      nil ->
        {:error, :not_found}

      file ->
        with :ok <- delete_storage(file.storage_key),
             {:ok, _deleted} <- Repo.delete(file) do
          Storage.update_user_storage(user_id)
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def rename_folder(user_id, folder_path, new_name) do
    with {:ok, normalized_source} <- normalize_folder(folder_path),
         false <- normalized_source == "",
         {:ok, normalized_name} <- normalize_filename(new_name) do
      move_folder(user_id, normalized_source, parent_folder(normalized_source), normalized_name)
    else
      true -> {:error, :invalid_folder_path}
      {:error, reason} -> {:error, reason}
    end
  end

  def move_folder(user_id, source_path, destination_folder_path, new_name \\ nil) do
    with {:ok, normalized_source} <- normalize_folder(source_path),
         {:ok, normalized_destination_folder} <- normalize_folder(destination_folder_path),
         false <- normalized_source == "",
         :ok <- ensure_folder_exists(user_id, normalized_source),
         normalized_new_name <- new_name || Path.basename(normalized_source),
         {:ok, valid_new_name} <- normalize_filename(normalized_new_name),
         target_path <- join_path(normalized_destination_folder, valid_new_name),
         :ok <- validate_folder_move_target(normalized_source, target_path),
         :ok <- ensure_target_folder_path_available(user_id, target_path, normalized_source),
         :ok <- ensure_folder_hierarchy(user_id, parent_folder(target_path)) do
      Repo.transaction(fn ->
        source_prefix = normalized_source <> "/"
        target_prefix = target_path <> "/"

        StoredFolder
        |> where(
          [f],
          f.user_id == ^user_id and
            (f.path == ^normalized_source or like(f.path, ^"#{source_prefix}%"))
        )
        |> Repo.all()
        |> Enum.each(fn folder ->
          new_folder_path = replace_prefix(folder.path, normalized_source, target_path)
          folder |> StoredFolder.changeset(%{path: new_folder_path}) |> Repo.update!()
        end)

        StoredFile
        |> where([f], f.user_id == ^user_id and like(f.path, ^"#{source_prefix}%"))
        |> Repo.all()
        |> Enum.each(fn file ->
          new_file_path = replace_prefix(file.path, normalized_source, target_path)
          file |> StoredFile.changeset(%{path: new_file_path}) |> Repo.update!()
        end)

        if is_nil(Repo.get_by(StoredFolder, user_id: user_id, path: target_path)) do
          %StoredFolder{}
          |> StoredFolder.changeset(%{user_id: user_id, path: target_path})
          |> Repo.insert!(on_conflict: :nothing)
        end

        {target_path, target_prefix}
      end)
      |> case do
        {:ok, {target_path, _target_prefix}} -> {:ok, target_path}
        {:error, reason} -> {:error, reason}
      end
    else
      true -> {:error, :invalid_folder_path}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_folder(user_id, folder_path) do
    with {:ok, normalized_folder} <- normalize_folder(folder_path),
         false <- normalized_folder == "",
         :ok <- ensure_folder_exists(user_id, normalized_folder) do
      prefix = normalized_folder <> "/"

      files =
        StoredFile
        |> where([f], f.user_id == ^user_id and like(f.path, ^"#{prefix}%"))
        |> Repo.all()

      with :ok <- delete_file_storage_entries(files),
           {:ok, _result} <-
             Repo.transaction(fn ->
               StoredFile
               |> where([f], f.user_id == ^user_id and like(f.path, ^"#{prefix}%"))
               |> Repo.delete_all()

               StoredFolder
               |> where(
                 [f],
                 f.user_id == ^user_id and
                   (f.path == ^normalized_folder or like(f.path, ^"#{prefix}%"))
               )
               |> Repo.delete_all()
             end) do
        Storage.update_user_storage(user_id)
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      true -> {:error, :invalid_folder_path}
      {:error, reason} -> {:error, reason}
    end
  end

  def bulk_delete(user_id, selections) when is_list(selections) do
    {folders, files} = parse_bulk_selections(selections)

    Enum.reduce_while(Enum.sort_by(folders, &String.length/1, :desc), :ok, fn folder, _acc ->
      case delete_folder(user_id, folder) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok ->
        Enum.reduce_while(files, :ok, fn file_id, _acc ->
          case delete_file(user_id, file_id) do
            :ok -> {:cont, :ok}
            {:error, :not_found} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def bulk_move(user_id, selections, destination_folder_path) when is_list(selections) do
    {folders, files} = parse_bulk_selections(selections)

    with {:ok, normalized_destination} <- normalize_folder(destination_folder_path),
         :ok <- ensure_folder_hierarchy(user_id, normalized_destination) do
      Enum.reduce_while(Enum.sort_by(folders, &String.length/1), :ok, fn folder, _acc ->
        case move_folder(user_id, folder, normalized_destination) do
          {:ok, _path} -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok ->
          Enum.reduce_while(files, :ok, fn file_id, _acc ->
            case move_file(user_id, file_id, normalized_destination) do
              {:ok, _file} -> {:cont, :ok}
              {:error, :not_found} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create_share(user_id, file_id, attrs \\ %{}) do
    with {:ok, expires_at} <- expires_at_from_attrs(attrs),
         {:ok, access_level} <- access_level_from_attrs(attrs),
         {:ok, password_hash} <- password_hash_from_attrs(attrs) do
      case get_file(user_id, file_id) do
        nil ->
          {:error, :not_found}

        %StoredFile{} = file ->
          %FileShare{}
          |> FileShare.changeset(%{
            drive_file_id: file.id,
            user_id: user_id,
            token: random_share_token(),
            expires_at: expires_at,
            access_level: access_level,
            password_hash: password_hash
          })
          |> Repo.insert()
      end
    end
  end

  def revoke_share(user_id, share_id) do
    query =
      from(s in FileShare,
        join: f in assoc(s, :stored_file),
        where: s.id == ^share_id and f.user_id == ^user_id and is_nil(s.revoked_at)
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      share ->
        share
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
    end
  end

  def get_active_share(token) when is_binary(token) do
    FileShare
    |> where([s], s.token == ^token and is_nil(s.revoked_at))
    |> where([s], is_nil(s.expires_at) or s.expires_at > ^DateTime.utc_now())
    |> preload(:stored_file)
    |> Repo.one()
  end

  def get_active_share(_token), do: nil

  def share_requires_password?(%FileShare{password_hash: hash}),
    do: is_binary(hash) and hash != ""

  def share_requires_password?(_share), do: false

  def verify_share_password(%FileShare{} = share, password) do
    cond do
      not share_requires_password?(share) -> true
      not is_binary(password) or password == "" -> false
      true -> Argon2.verify_pass(password, share.password_hash)
    end
  end

  def share_inline_view?(%FileShare{access_level: "view", stored_file: %StoredFile{} = file}) do
    inline_viewable_content_type?(file.content_type)
  end

  def share_inline_view?(_share), do: false

  def inline_viewable_content_type?(content_type) when is_binary(content_type) do
    normalized =
      content_type
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()

    cond do
      normalized in ["image/svg+xml", "image/svg+xml-compressed"] ->
        false

      String.starts_with?(normalized, ["image/", "video/", "audio/"]) ->
        true

      normalized in ["application/pdf", "application/json", "text/plain"] ->
        true

      true ->
        false
    end
  end

  def inline_viewable_content_type?(_), do: false

  def increment_share_download_count(%FileShare{} = share) do
    share
    |> Ecto.Changeset.change(download_count: (share.download_count || 0) + 1)
    |> Repo.update()
  end

  def read_file(%StoredFile{} = file) do
    case storage_adapter() do
      :local -> read_local(file.storage_key)
      :s3 -> read_s3(file.storage_key)
    end
  end

  def storage_used(user_id) do
    case StoredFile
         |> where([f], f.user_id == ^user_id)
         |> select([f], sum(f.size))
         |> Repo.one() do
      nil -> 0
      %Decimal{} = decimal -> Decimal.to_integer(decimal)
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp persist_file(nil, attrs) do
    case %StoredFile{} |> StoredFile.changeset(attrs) |> Repo.insert() do
      {:ok, file} -> {:ok, file, nil}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp persist_file(%StoredFile{} = existing_file, attrs) do
    old_storage_key = existing_file.storage_key

    case existing_file |> StoredFile.changeset(attrs) |> Repo.update() do
      {:ok, file} -> {:ok, file, old_storage_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp validate_file_size(size) when size <= 0, do: {:error, :empty_file}

  defp validate_file_size(size) when size > @default_max_upload_size do
    {:error, {:file_too_large, @default_max_upload_size}}
  end

  defp validate_file_size(_size), do: :ok

  defp validate_storage_limit(%User{is_admin: true}, _existing_file, _size), do: :ok

  defp validate_storage_limit(%User{id: user_id}, existing_file, new_size) do
    existing_size = if existing_file, do: existing_file.size || 0, else: 0
    additional_bytes = max(new_size - existing_size, 0)

    if Storage.would_exceed_limit?(user_id, additional_bytes) do
      {:error, :storage_limit_exceeded}
    else
      :ok
    end
  end

  defp ensure_parent_folder_hierarchy(user_id, file_path) do
    ensure_folder_hierarchy(user_id, parent_folder(file_path))
  end

  defp ensure_folder_hierarchy(_user_id, ""), do: :ok

  defp ensure_folder_hierarchy(user_id, normalized_folder) when is_binary(normalized_folder) do
    with {:ok, folder} <- normalize_folder(normalized_folder) do
      Repo.transaction(fn -> ensure_folder_hierarchy!(user_id, folder) end)
      |> case do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_folder_hierarchy!(user_id, folder) do
    folder
    |> folder_ancestors()
    |> Enum.each(fn path ->
      %StoredFolder{}
      |> StoredFolder.changeset(%{user_id: user_id, path: path})
      |> Repo.insert!(on_conflict: :nothing)
    end)
  end

  defp folder_ancestors(""), do: []

  defp folder_ancestors(folder) do
    folder
    |> String.split("/", trim: true)
    |> Enum.reduce({[], ""}, fn segment, {paths, prefix} ->
      current = if prefix == "", do: segment, else: prefix <> "/" <> segment
      {paths ++ [current], current}
    end)
    |> elem(0)
  end

  defp ensure_target_file_path_available(user_id, path, existing_id) do
    cond do
      file_conflict?(user_id, path, existing_id) -> {:error, :path_taken}
      folder_exists?(user_id, path) -> {:error, :path_taken}
      true -> :ok
    end
  end

  defp ensure_target_folder_path_available(user_id, path, source_path) do
    cond do
      is_binary(source_path) and path == source_path -> :ok
      folder_exists?(user_id, path) -> {:error, :path_taken}
      file_exists?(user_id, path) -> {:error, :path_taken}
      true -> :ok
    end
  end

  defp validate_folder_move_target(source_path, target_path) do
    cond do
      target_path == source_path ->
        {:error, :path_taken}

      String.starts_with?(target_path <> "/", source_path <> "/") ->
        {:error, :invalid_move_target}

      true ->
        :ok
    end
  end

  defp file_conflict?(user_id, path, existing_id) do
    query = from(f in StoredFile, where: f.user_id == ^user_id and f.path == ^path)
    query = if existing_id, do: where(query, [f], f.id != ^existing_id), else: query
    Repo.exists?(query)
  end

  defp file_exists?(user_id, path) do
    Repo.exists?(from(f in StoredFile, where: f.user_id == ^user_id and f.path == ^path))
  end

  defp folder_exists?(_user_id, ""), do: true

  defp folder_exists?(user_id, path) do
    prefix = path <> "/"

    Repo.exists?(from(f in StoredFolder, where: f.user_id == ^user_id and f.path == ^path)) or
      Repo.exists?(
        from(f in StoredFolder, where: f.user_id == ^user_id and like(f.path, ^"#{prefix}%"))
      ) or
      Repo.exists?(
        from(f in StoredFile, where: f.user_id == ^user_id and like(f.path, ^"#{prefix}%"))
      )
  end

  defp ensure_folder_exists(user_id, path) do
    if folder_exists?(user_id, path), do: :ok, else: {:error, :not_found}
  end

  defp build_visible_path(folder_path, filename) do
    with {:ok, normalized_folder} <- normalize_folder_path(folder_path),
         {:ok, normalized_filename} <- normalize_filename(filename) do
      {:ok, join_path(normalized_folder, normalized_filename)}
    end
  end

  defp normalize_file_path(path) when is_binary(path) do
    normalized =
      path
      |> String.trim()
      |> String.trim("/")
      |> String.replace("\\", "/")

    case String.split(normalized, "/", trim: true) do
      [] ->
        {:error, :invalid_filename}

      segments ->
        {folder_segments, [filename]} = Enum.split(segments, length(segments) - 1)

        with {:ok, folder} <- normalize_folder_path(Enum.join(folder_segments, "/")),
             {:ok, normalized_filename} <- normalize_filename(filename) do
          {:ok, join_path(folder, normalized_filename)}
        end
    end
  end

  defp normalize_file_path(_), do: {:error, :invalid_filename}

  defp normalize_folder_path(nil), do: {:ok, ""}

  defp normalize_folder_path(folder_path) when is_binary(folder_path) do
    normalized =
      folder_path
      |> String.trim()
      |> String.trim("/")
      |> String.replace("\\", "/")

    segments = String.split(normalized, "/", trim: true)

    cond do
      normalized == "" -> {:ok, ""}
      Enum.any?(segments, &invalid_path_segment?/1) -> {:error, :invalid_folder_path}
      true -> {:ok, Enum.join(segments, "/")}
    end
  end

  defp normalize_folder_path(_), do: {:error, :invalid_folder_path}

  defp normalize_filename(filename) when is_binary(filename) do
    normalized = filename |> Path.basename() |> String.trim()

    cond do
      normalized == "" -> {:error, :invalid_filename}
      invalid_path_segment?(normalized) -> {:error, :invalid_filename}
      true -> {:ok, normalized}
    end
  end

  defp normalize_filename(_), do: {:error, :invalid_filename}

  defp invalid_path_segment?(segment) do
    trimmed = String.trim(segment)
    trimmed == "" or trimmed in [".", ".."] or String.contains?(trimmed, [<<0>>, "/", "\\"])
  end

  defp files_in_folder(files, current_folder) do
    Enum.filter(files, &(parent_folder(&1.path) == current_folder))
  end

  defp build_folder_entries(folders, files, current_folder, opts) do
    folder_paths =
      (Enum.map(folders, &immediate_child_folder_from_folder(&1.path, current_folder)) ++
         Enum.map(files, &immediate_child_folder_from_file(&1.path, current_folder)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    folder_paths
    |> Enum.map(fn path ->
      %{
        name: Path.basename(path),
        path: path,
        file_count: count_files_under(files, path),
        updated_at: latest_update_under(files, folders, path)
      }
    end)
    |> filter_folders(opts.search)
    |> sort_folders(opts.sort)
  end

  defp count_files_under(files, folder_path) do
    prefix = folder_path <> "/"
    Enum.count(files, &String.starts_with?(&1.path, prefix))
  end

  defp latest_update_under(files, folders, folder_path) do
    prefix = folder_path <> "/"

    ((Enum.filter(files, &String.starts_with?(&1.path, prefix)) |> Enum.map(& &1.updated_at)) ++
       (Enum.filter(folders, &(&1.path == folder_path or String.starts_with?(&1.path, prefix)))
        |> Enum.map(& &1.updated_at)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp immediate_child_folder(path, current_folder) do
    current_prefix = if current_folder == "", do: "", else: current_folder <> "/"

    if String.starts_with?(path, current_prefix) do
      remainder =
        if current_prefix == "", do: path, else: String.trim_leading(path, current_prefix)

      case String.split(remainder, "/", parts: 2) do
        [_single] -> nil
        [child, _rest] -> join_path(current_folder, child)
      end
    else
      nil
    end
  end

  defp immediate_child_folder_from_folder(path, current_folder) do
    cond do
      path == current_folder ->
        nil

      current_folder == "" and not String.contains?(path, "/") ->
        path

      current_folder != "" and String.starts_with?(path, current_folder <> "/") ->
        remainder = String.trim_leading(path, current_folder <> "/")

        case String.split(remainder, "/", parts: 2) do
          [child] -> join_path(current_folder, child)
          [child, _rest] -> join_path(current_folder, child)
        end

      true ->
        nil
    end
  end

  defp immediate_child_folder_from_file(path, current_folder),
    do: immediate_child_folder(path, current_folder)

  defp parent_folder(path) do
    case String.split(path, "/", trim: true) do
      [_filename] -> ""
      segments -> segments |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  defp breadcrumbs(""), do: [%{name: "My Drive", path: ""}]

  defp breadcrumbs(folder_path) do
    folder_path
    |> String.split("/", trim: true)
    |> Enum.reduce({[%{name: "My Drive", path: ""}], ""}, fn segment, {crumbs, prefix} ->
      path = join_path(prefix, segment)
      {crumbs ++ [%{name: segment, path: path}], path}
    end)
    |> elem(0)
  end

  defp normalize_list_opts(opts) do
    search =
      Map.get(opts, :search) || Map.get(opts, "search") || Map.get(opts, :q) || Map.get(opts, "q") ||
        ""

    sort = Map.get(opts, :sort) || Map.get(opts, "sort") || "updated_desc"
    filter = Map.get(opts, :filter) || Map.get(opts, "filter") || "all"

    %{
      search: String.trim(to_string(search)),
      sort: normalize_sort(sort),
      filter: normalize_filter(filter)
    }
  end

  defp normalize_sort(sort) when sort in @valid_sort_values, do: sort
  defp normalize_sort(sort) when is_binary(sort) and sort in @valid_sort_values, do: sort
  defp normalize_sort(_sort), do: "updated_desc"

  defp normalize_filter(filter) when filter in @valid_filter_values, do: filter

  defp normalize_filter(filter) when is_binary(filter) and filter in @valid_filter_values,
    do: filter

  defp normalize_filter(_filter), do: "all"

  defp filtered_folder_entries(folders, files, current_folder, opts) do
    if opts.filter == "all" do
      build_folder_entries(folders, files, current_folder, opts)
    else
      []
    end
  end

  defp apply_file_filter(files, "all"), do: files

  defp apply_file_filter(files, "recent") do
    threshold = DateTime.utc_now() |> DateTime.add(-1_209_600, :second)

    Enum.filter(files, fn file ->
      case file.updated_at do
        %DateTime{} = updated_at -> DateTime.compare(updated_at, threshold) != :lt
        _ -> false
      end
    end)
  end

  defp apply_file_filter(files, "images") do
    Enum.filter(files, &content_type_match?(&1.content_type, :images))
  end

  defp apply_file_filter(files, "documents") do
    Enum.filter(files, &content_type_match?(&1.content_type, :documents))
  end

  defp apply_file_filter(files, "media") do
    Enum.filter(files, &content_type_match?(&1.content_type, :media))
  end

  defp apply_file_filter(files, "shared") do
    Enum.filter(files, &match?([_ | _], &1.shares || []))
  end

  defp apply_file_filter(files, _filter), do: files

  defp content_type_match?(content_type, :images),
    do: is_binary(content_type) and String.starts_with?(content_type, "image/")

  defp content_type_match?(content_type, :media),
    do:
      is_binary(content_type) and
        String.starts_with?(content_type, ["image/", "video/", "audio/"])

  defp content_type_match?(content_type, :documents) do
    is_binary(content_type) and
      (String.starts_with?(content_type, "text/") or
         content_type in [
           "application/pdf",
           "application/json",
           "application/msword",
           "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
           "application/vnd.ms-excel",
           "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
           "application/vnd.ms-powerpoint",
           "application/vnd.openxmlformats-officedocument.presentationml.presentation"
         ])
  end

  defp filter_files(files, ""), do: files

  defp filter_files(files, search) do
    needle = String.downcase(search)

    Enum.filter(files, fn file ->
      String.contains?(String.downcase(file.original_filename || file.path), needle) or
        String.contains?(String.downcase(file.path), needle)
    end)
  end

  defp filter_folders(folders, ""), do: folders

  defp filter_folders(folders, search) do
    needle = String.downcase(search)
    Enum.filter(folders, &String.contains?(String.downcase(&1.name), needle))
  end

  defp sort_files(files, "name_asc"),
    do: Enum.sort_by(files, &String.downcase(&1.original_filename || &1.path), :asc)

  defp sort_files(files, "name_desc"),
    do: Enum.sort_by(files, &String.downcase(&1.original_filename || &1.path), :desc)

  defp sort_files(files, "updated_asc"),
    do: Enum.sort_by(files, & &1.updated_at, {:asc, DateTime})

  defp sort_files(files, "updated_desc"),
    do: Enum.sort_by(files, & &1.updated_at, {:desc, DateTime})

  defp sort_files(files, "path_asc"), do: Enum.sort_by(files, &String.downcase(&1.path), :asc)
  defp sort_files(files, "path_desc"), do: Enum.sort_by(files, &String.downcase(&1.path), :desc)

  defp sort_files(files, "size_asc"), do: Enum.sort_by(files, &(&1.size || 0), :asc)
  defp sort_files(files, "size_desc"), do: Enum.sort_by(files, &(&1.size || 0), :desc)
  defp sort_files(files, _sort), do: files

  defp sort_folders(folders, "path_asc"),
    do: Enum.sort_by(folders, &String.downcase(&1.path), :asc)

  defp sort_folders(folders, "path_desc"),
    do: Enum.sort_by(folders, &String.downcase(&1.path), :desc)

  defp sort_folders(folders, "name_desc"),
    do: Enum.sort_by(folders, &String.downcase(&1.name), :desc)

  defp sort_folders(folders, "updated_asc"),
    do: Enum.sort_by(folders, &(&1.updated_at || ~U[1970-01-01 00:00:00Z]), {:asc, DateTime})

  defp sort_folders(folders, "updated_desc"),
    do: Enum.sort_by(folders, &(&1.updated_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})

  defp sort_folders(folders, _sort), do: Enum.sort_by(folders, &String.downcase(&1.name), :asc)

  defp parse_bulk_selections(selections) do
    Enum.reduce(selections, {[], []}, fn selection, {folders, files} ->
      cond do
        String.starts_with?(selection, "folder:") ->
          {[String.replace_prefix(selection, "folder:", "") | folders], files}

        String.starts_with?(selection, "file:") ->
          case Integer.parse(String.replace_prefix(selection, "file:", "")) do
            {id, ""} -> {folders, [id | files]}
            _ -> {folders, files}
          end

        true ->
          {folders, files}
      end
    end)
    |> then(fn {folders, files} -> {Enum.uniq(folders), Enum.uniq(files)} end)
  end

  defp active_shares_query do
    from(s in FileShare,
      where: is_nil(s.revoked_at),
      where: is_nil(s.expires_at) or s.expires_at > ^DateTime.utc_now(),
      order_by: [desc: s.inserted_at]
    )
  end

  defp expires_at_from_attrs(%{"expires_in" => expires_in}),
    do: expires_at_from_option(expires_in)

  defp expires_at_from_attrs(%{expires_in: expires_in}), do: expires_at_from_option(expires_in)
  defp expires_at_from_attrs(_attrs), do: {:ok, nil}

  defp access_level_from_attrs(%{"access_level" => access_level}),
    do: access_level_from_option(access_level)

  defp access_level_from_attrs(%{access_level: access_level}),
    do: access_level_from_option(access_level)

  defp access_level_from_attrs(_attrs), do: {:ok, "download"}

  defp access_level_from_option(level) when level in @valid_share_access_levels, do: {:ok, level}
  defp access_level_from_option(_level), do: {:error, :invalid_share_access}

  defp password_hash_from_attrs(%{"password" => password}), do: hash_share_password(password)
  defp password_hash_from_attrs(%{password: password}), do: hash_share_password(password)
  defp password_hash_from_attrs(_attrs), do: {:ok, nil}

  defp hash_share_password(password) when not is_binary(password) or password == "",
    do: {:ok, nil}

  defp hash_share_password(password) when byte_size(password) < 4 do
    {:error, :invalid_share_password}
  end

  defp hash_share_password(password) do
    {:ok, Argon2.hash_pwd_salt(password)}
  end

  defp expires_at_from_option(nil), do: {:ok, nil}
  defp expires_at_from_option(""), do: {:ok, nil}
  defp expires_at_from_option("never"), do: {:ok, nil}

  defp expires_at_from_option("1d"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option("7d"),
    do: {:ok, DateTime.utc_now() |> DateTime.add(604_800, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option("30d"),
    do:
      {:ok, DateTime.utc_now() |> DateTime.add(2_592_000, :second) |> DateTime.truncate(:second)}

  defp expires_at_from_option(_), do: {:error, :invalid_share_expiry}

  defp normalize_content_type(content_type, filename) do
    value =
      content_type
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()
      |> to_string()

    if value == "", do: MIME.from_path(filename || "") || "application/octet-stream", else: value
  end

  defp put_storage_binary(user_id, binary, filename, content_type) do
    storage_key = generate_storage_key(user_id, filename)

    case storage_adapter() do
      :local ->
        path = local_storage_path(storage_key)
        File.mkdir_p!(Path.dirname(path))

        case File.write(path, binary) do
          :ok -> {:ok, storage_key}
          {:error, reason} -> {:error, reason}
        end

      :s3 ->
        bucket = get_bucket()

        case S3.put_object(bucket, storage_key, binary, content_type: content_type)
             |> ExAws.request() do
          {:ok, _response} -> {:ok, storage_key}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_local(storage_key) do
    case File.read(local_storage_path(storage_key)) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_s3(storage_key) do
    case S3.get_object(get_bucket(), storage_key) |> ExAws.request() do
      {:ok, %{body: binary}} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_file_storage_entries(files) do
    Enum.reduce_while(files, :ok, fn file, _acc ->
      case delete_storage(file.storage_key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_storage(storage_key) do
    case storage_adapter() do
      :local ->
        case File.rm(local_storage_path(storage_key)) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :s3 ->
        case S3.delete_object(get_bucket(), storage_key) |> ExAws.request() do
          {:ok, _response} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_delete_storage(nil), do: :ok
  defp maybe_delete_storage(storage_key), do: delete_storage(storage_key)

  defp replace_prefix(path, source_prefix, target_prefix) when path == source_prefix,
    do: target_prefix

  defp replace_prefix(path, source_prefix, target_prefix),
    do: String.replace_prefix(path, source_prefix <> "/", target_prefix <> "/")

  defp join_path("", name), do: name
  defp join_path(folder, name), do: folder <> "/" <> name

  defp file_name_from_path(path), do: Path.basename(path)

  defp generate_storage_key(user_id, filename) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    sanitized = sanitize_storage_filename(filename)
    "cloud-files/#{user_id}/#{random}/#{sanitized}"
  end

  defp sanitize_storage_filename(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> case do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      value -> String.slice(value, 0, 100)
    end
  end

  defp sanitize_storage_filename(_), do: "file"

  defp local_storage_path(storage_key) do
    uploads_dir =
      Application.get_env(:elektrine, :uploads, [])[:uploads_dir] || "priv/static/uploads"

    Path.join(uploads_dir, storage_key)
  end

  defp storage_adapter do
    Application.get_env(:elektrine, :uploads, [])[:adapter] || :local
  end

  defp get_bucket do
    Application.get_env(:elektrine, :uploads, [])[:bucket] || raise "R2 bucket not configured"
  end

  defp random_share_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
