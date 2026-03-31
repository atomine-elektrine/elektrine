defmodule ElektrineWeb.FilesLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts.Storage
  alias Elektrine.Files

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: ~p"/login")}

      user ->
        {:ok,
         socket
         |> assign(:page_title, "Files")
         |> assign(:folder_path, "")
         |> assign(:current_folder, "")
         |> assign(:breadcrumbs, [%{name: "All files", path: ""}])
         |> assign(:folders, [])
         |> assign(:files, [])
         |> assign(:search_query, "")
         |> assign(:sort_by, "updated_desc")
         |> assign(:sort_options, Files.sort_options())
         |> assign(:share_expiry_options, Files.share_expiry_options())
         |> assign(:share_access_options, Files.share_access_options())
         |> assign(:selected_items, MapSet.new())
         |> assign(:rename_target, nil)
         |> assign(:move_target, nil)
         |> assign(:bulk_move_open, false)
         |> assign(:bulk_move_path, "")
         |> assign(:show_new_folder_form, false)
         |> assign(:new_folder_name, "")
         |> assign(:storage_info, Storage.get_storage_info(user.id))
         |> allow_upload(:files,
           accept: :any,
           max_entries: 10,
           max_file_size: Files.max_upload_size(),
           auto_upload: true
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user

    case Files.list_folder(user.id, Map.get(params, "folder", ""), params) do
      {:ok, folder_view} ->
        {:noreply, apply_folder_view(socket, folder_view, user.id)}

      {:error, :invalid_folder_path} ->
        {:noreply,
         socket
         |> put_flash(:error, "Folder path is invalid")
         |> push_patch(to: ~p"/account/files")}
    end
  end

  @impl true
  def handle_event("validate_upload", %{"upload" => params}, socket) do
    {:noreply,
     assign(socket, :folder_path, Map.get(params, "folder", socket.assigns.current_folder))}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("upload_files", %{"upload" => params}, socket) do
    user = socket.assigns.current_user
    folder_path = Map.get(params, "folder", socket.assigns.current_folder)

    results =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        {:ok, Files.upload_file(user, folder_path, upload)}
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))

    error_messages =
      results |> Enum.filter(&match?({:error, _}, &1)) |> Enum.map(&upload_error_message/1)

    socket =
      socket
      |> refresh_files(user.id, folder_path)
      |> put_upload_flash(success_count, error_messages)

    {:noreply, socket}
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    folder = socket.assigns.current_folder
    query = Map.get(params, "q", "")
    sort = Map.get(params, "sort", socket.assigns.sort_by)
    {:noreply, push_patch(socket, to: files_path(folder, query, sort))}
  end

  def handle_event("create_folder", %{"folder" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user
    path = join_path(socket.assigns.current_folder, name)

    case Files.create_folder(user.id, path) do
      {:ok, _folder} ->
        {:noreply,
         socket
         |> assign(:show_new_folder_form, false)
         |> assign(:new_folder_name, "")
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Folder created")}

      {:error, :path_taken} ->
        {:noreply, put_flash(socket, :error, "A file or folder already uses that path")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create folder")}
    end
  end

  def handle_event("toggle_new_folder", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_folder_form, not socket.assigns.show_new_folder_form)
     |> assign(:new_folder_name, "")}
  end

  def handle_event("cancel_new_folder", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_folder_form, false)
     |> assign(:new_folder_name, "")}
  end

  def handle_event("delete_file", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         :ok <- Files.delete_file(user.id, file_id) do
      {:noreply,
       socket
       |> refresh_files(user.id, socket.assigns.current_folder)
       |> put_flash(:info, "File deleted")}
    else
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "File not found")}
      _ -> {:noreply, put_flash(socket, :error, "Could not delete file")}
    end
  end

  def handle_event("delete_folder", %{"path" => path}, socket) do
    user = socket.assigns.current_user

    case Files.delete_folder(user.id, path) do
      :ok ->
        {:noreply,
         socket
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Folder deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Folder not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete folder")}
    end
  end

  def handle_event("start_rename", %{"type" => type, "id" => id}, socket) do
    {:noreply, assign(socket, :rename_target, %{type: type, id: id})}
  end

  def handle_event("start_rename", %{"type" => type, "path" => path}, socket) do
    {:noreply, assign(socket, :rename_target, %{type: type, path: path})}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :rename_target, nil)}
  end

  def handle_event("rename_file", %{"rename" => %{"id" => id, "name" => name}}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         {:ok, _file} <- Files.rename_file(user.id, file_id, name) do
      {:noreply,
       socket
       |> assign(:rename_target, nil)
       |> refresh_files(user.id, socket.assigns.current_folder)
       |> put_flash(:info, "File renamed")}
    else
      {:error, :path_taken} ->
        {:noreply, put_flash(socket, :error, "That filename is already in use")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not rename file")}
    end
  end

  def handle_event(
        "rename_folder",
        %{"rename_folder" => %{"path" => path, "name" => name}},
        socket
      ) do
    user = socket.assigns.current_user

    case Files.rename_folder(user.id, path, name) do
      {:ok, new_path} ->
        current_folder =
          maybe_update_current_folder(socket.assigns.current_folder, path, new_path)

        {:noreply,
         socket
         |> assign(:rename_target, nil)
         |> refresh_files(user.id, current_folder)
         |> put_flash(:info, "Folder renamed")}

      {:error, :path_taken} ->
        {:noreply, put_flash(socket, :error, "That folder name is already in use")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not rename folder")}
    end
  end

  def handle_event("start_move", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:move_target, %{type: type, id: id})
     |> assign(:bulk_move_open, false)
     |> assign(:bulk_move_path, socket.assigns.current_folder)}
  end

  def handle_event("start_move", %{"type" => type, "path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:move_target, %{type: type, path: path})
     |> assign(:bulk_move_open, false)
     |> assign(:bulk_move_path, socket.assigns.current_folder)}
  end

  def handle_event("cancel_move", _params, socket) do
    {:noreply, assign(socket, :move_target, nil)}
  end

  def handle_event("move_file", %{"move" => %{"id" => id, "folder" => folder}}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         {:ok, _file} <- Files.move_file(user.id, file_id, folder) do
      {:noreply,
       socket
       |> assign(:move_target, nil)
       |> refresh_files(user.id, socket.assigns.current_folder)
       |> put_flash(:info, "File moved")}
    else
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not move file")}
    end
  end

  def handle_event(
        "move_folder",
        %{"move_folder" => %{"path" => path, "folder" => folder}},
        socket
      ) do
    user = socket.assigns.current_user

    case Files.move_folder(user.id, path, folder) do
      {:ok, _new_path} ->
        {:noreply,
         socket
         |> assign(:move_target, nil)
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Folder moved")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not move folder")}
    end
  end

  def handle_event("toggle_select", %{"token" => token}, socket) do
    selected_items =
      if MapSet.member?(socket.assigns.selected_items, token) do
        MapSet.delete(socket.assigns.selected_items, token)
      else
        MapSet.put(socket.assigns.selected_items, token)
      end

    {:noreply, assign(socket, :selected_items, selected_items)}
  end

  def handle_event("select_visible", _params, socket) do
    {:noreply, assign(socket, :selected_items, MapSet.new(visible_selection_tokens(socket)))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_items, MapSet.new())}
  end

  def handle_event("open_bulk_move", _params, socket) do
    {:noreply, assign(socket, :bulk_move_open, true)}
  end

  def handle_event("close_bulk_move", _params, socket) do
    {:noreply, assign(socket, :bulk_move_open, false)}
  end

  def handle_event("bulk_delete", _params, socket) do
    user = socket.assigns.current_user

    case Files.bulk_delete(user.id, MapSet.to_list(socket.assigns.selected_items)) do
      :ok ->
        {:noreply,
         socket
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Selected items deleted")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete selected items")}
    end
  end

  def handle_event("bulk_move", %{"bulk_move" => %{"folder" => folder}}, socket) do
    user = socket.assigns.current_user

    case Files.bulk_move(user.id, MapSet.to_list(socket.assigns.selected_items), folder) do
      :ok ->
        {:noreply,
         socket
         |> assign(:bulk_move_open, false)
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Selected items moved")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not move selected items")}
    end
  end

  def handle_event("create_share", %{"share" => %{"file_id" => id} = params}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         {:ok, _share} <- Files.create_share(user.id, file_id, params) do
      {:noreply,
       socket
       |> refresh_files(user.id, socket.assigns.current_folder)
       |> put_flash(:info, "Share link created")}
    else
      {:error, :invalid_share_expiry} ->
        {:noreply, put_flash(socket, :error, "Share expiry is invalid")}

      {:error, :invalid_share_access} ->
        {:noreply, put_flash(socket, :error, "Share access level is invalid")}

      {:error, :invalid_share_password} ->
        {:noreply, put_flash(socket, :error, "Share password must be at least 4 characters")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "File not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create share link")}
    end
  end

  def handle_event("revoke_share", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, share_id} <- parse_id(id),
         {:ok, _share} <- Files.revoke_share(user.id, share_id) do
      {:noreply,
       socket
       |> refresh_files(user.id, socket.assigns.current_folder)
       |> put_flash(:info, "Share link revoked")}
    else
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not revoke share link")}
    end
  end

  defp refresh_files(socket, user_id, folder_path) do
    case Files.list_folder(user_id, folder_path, %{
           q: socket.assigns.search_query,
           sort: socket.assigns.sort_by
         }) do
      {:ok, folder_view} -> apply_folder_view(socket, folder_view, user_id)
      {:error, _reason} -> socket
    end
  end

  defp apply_folder_view(socket, folder_view, user_id) do
    socket
    |> assign(:current_folder, folder_view.current_folder)
    |> assign(:folder_path, folder_view.current_folder)
    |> assign(:breadcrumbs, folder_view.breadcrumbs)
    |> assign(:folders, folder_view.folders)
    |> assign(:files, folder_view.files)
    |> assign(:search_query, folder_view.search_query)
    |> assign(:sort_by, folder_view.sort_by)
    |> assign(:selected_items, MapSet.new())
    |> assign(:rename_target, nil)
    |> assign(:move_target, nil)
    |> assign(:bulk_move_open, false)
    |> assign(:bulk_move_path, folder_view.current_folder)
    |> assign(:show_new_folder_form, false)
    |> assign(:storage_info, Storage.get_storage_info(user_id))
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp put_upload_flash(socket, success_count, []) when success_count > 0 do
    put_flash(socket, :info, uploaded_message(success_count))
  end

  defp put_upload_flash(socket, _success_count, error_messages) when error_messages != [] do
    put_flash(socket, :error, Enum.join(Enum.uniq(error_messages), "; "))
  end

  defp put_upload_flash(socket, _success_count, _error_messages), do: socket

  defp uploaded_message(1), do: "Uploaded 1 file"
  defp uploaded_message(count), do: "Uploaded #{count} files"

  defp upload_error_message({:error, %Ecto.Changeset{} = changeset}) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {message, _opts}} ->
      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
  end

  defp upload_error_message({:error, {:file_too_large, limit}}),
    do: "File exceeds #{Storage.format_bytes(limit)} upload limit"

  defp upload_error_message({:error, :storage_limit_exceeded}),
    do: "Upload would exceed your storage limit"

  defp upload_error_message({:error, :invalid_folder_path}), do: "Folder path is invalid"
  defp upload_error_message({:error, :invalid_filename}), do: "Filename is invalid"
  defp upload_error_message({:error, :empty_file}), do: "Empty files cannot be uploaded"
  defp upload_error_message({:error, reason}), do: "Upload failed: #{inspect(reason)}"

  defp visible_selection_tokens(socket) do
    Enum.map(socket.assigns.folders, &folder_token(&1.path)) ++
      Enum.map(socket.assigns.files, &file_token(&1.id))
  end

  defp file_token(id), do: "file:#{id}"
  defp folder_token(path), do: "folder:#{path}"
  defp selected?(selected_items, token), do: MapSet.member?(selected_items, token)

  defp current_folder_name(""), do: "All files"

  defp current_folder_name(folder) when is_binary(folder),
    do: folder |> String.split("/", trim: true) |> List.last()

  defp file_display_name(file), do: file.original_filename || Path.basename(file.path)

  defp file_parent_label(file, current_folder), do: parent_folder_label(file.path, current_folder)

  defp parent_folder_label(path, current_folder) do
    parent = path |> String.split("/", trim: true) |> Enum.drop(-1) |> Enum.join("/")

    cond do
      parent == "" -> "Root"
      parent == current_folder -> "Current folder"
      true -> parent
    end
  end

  defp file_kind_label(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "Image"
      String.starts_with?(content_type, "video/") -> "Video"
      String.starts_with?(content_type, "audio/") -> "Audio"
      content_type == "application/pdf" -> "PDF"
      String.starts_with?(content_type, "text/") -> "Text"
      true -> "File"
    end
  end

  defp file_kind_label(_), do: "File"

  defp file_icon_name(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "hero-photo"
      String.starts_with?(content_type, "video/") -> "hero-film"
      String.starts_with?(content_type, "audio/") -> "hero-musical-note"
      content_type == "application/pdf" -> "hero-document-text"
      String.starts_with?(content_type, "text/") -> "hero-document-duplicate"
      true -> "hero-document"
    end
  end

  defp file_icon_name(_), do: "hero-document"

  defp kind_badge_class(content_type) do
    cond do
      is_binary(content_type) and String.starts_with?(content_type, "image/") ->
        "bg-info/15 text-info"

      is_binary(content_type) and String.starts_with?(content_type, "video/") ->
        "bg-secondary/15 text-secondary"

      is_binary(content_type) and String.starts_with?(content_type, "audio/") ->
        "bg-accent/15 text-accent"

      content_type == "application/pdf" ->
        "bg-error/15 text-error"

      is_binary(content_type) and String.starts_with?(content_type, "text/") ->
        "bg-success/15 text-success"

      true ->
        "bg-base-200 text-base-content/70"
    end
  end

  defp visible_share_count(files),
    do: Enum.reduce(files, 0, fn file, acc -> acc + length(file.shares || []) end)

  defp share_url(share), do: url(~p"/files/share/#{share.token}")
  defp share_password_protected?(share), do: Files.share_requires_password?(share)
  defp inline_viewable?(content_type), do: Files.inline_viewable_content_type?(content_type)

  defp image_preview?(content_type),
    do: is_binary(content_type) and String.starts_with?(content_type, "image/")

  defp files_path(folder, query, sort) do
    normalized_sort = if sort == "updated_desc", do: nil, else: sort

    params =
      [folder: blank_to_nil(folder), q: blank_to_nil(query), sort: blank_to_nil(normalized_sort)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/account/files?#{params}"
  end

  defp maybe_update_current_folder(current_folder, old_prefix, new_prefix) do
    cond do
      current_folder == old_prefix ->
        new_prefix

      String.starts_with?(current_folder, old_prefix <> "/") ->
        String.replace_prefix(current_folder, old_prefix <> "/", new_prefix <> "/")

      true ->
        current_folder
    end
  end

  defp join_path("", name), do: String.trim(name)
  defp join_path(folder, name), do: folder <> "/" <> String.trim(name)
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
