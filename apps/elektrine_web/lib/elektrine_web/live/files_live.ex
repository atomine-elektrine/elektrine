defmodule ElektrineWeb.FilesLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Accounts.Storage
  alias Elektrine.Files
  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_user do
      nil ->
        {:ok, redirect(socket, to: Elektrine.Paths.login_path())}

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
         |> assign(:active_filter, "all")
         |> assign(:sort_by, "updated_desc")
         |> assign(:sort_options, Files.sort_options())
         |> assign(:quick_filter_options, Files.quick_filter_options())
         |> assign(:share_expiry_options, Files.share_expiry_options())
         |> assign(:share_access_options, Files.share_access_options())
         |> assign(:selected_items, MapSet.new())
         |> assign(:rename_target, nil)
         |> assign(:move_target, nil)
         |> assign(:bulk_move_open, false)
         |> assign(:bulk_move_path, "")
         |> assign(:show_new_folder_form, false)
         |> assign(:new_folder_name, "")
         |> assign(:tree_expanded_paths, MapSet.new())
         |> assign(:folder_tree, [])
         |> assign(:context_menu, nil)
         |> assign(:active_file, nil)
         |> assign(:active_folder, nil)
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
    filter = Map.get(params, "filter", socket.assigns.active_filter)
    {:noreply, push_patch(socket, to: files_path(folder, query, sort, filter))}
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
     |> assign(:new_folder_name, "")
     |> assign(:context_menu, nil)}
  end

  def handle_event("cancel_new_folder", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_folder_form, false)
     |> assign(:new_folder_name, "")
     |> assign(:context_menu, nil)}
  end

  def handle_event("delete_file", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         :ok <- Files.delete_file(user.id, file_id) do
      {:noreply,
       socket
       |> assign(:active_file, nil)
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
         |> assign(:active_folder, nil)
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Folder deleted")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Folder not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete folder")}
    end
  end

  def handle_event("start_rename", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:rename_target, %{type: type, id: id})
     |> assign(:context_menu, nil)}
  end

  def handle_event("start_rename", %{"type" => type, "path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:rename_target, %{type: type, path: path})
     |> assign(:context_menu, nil)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :rename_target, nil)}
  end

  def handle_event("open_manage_file", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         %Files.StoredFile{} = file <- Enum.find(Files.list_files(user.id), &(&1.id == file_id)) do
      {:noreply,
       socket
       |> assign(:active_file, file)
       |> assign(:active_folder, nil)
       |> assign(:context_menu, nil)}
    else
      _ -> {:noreply, put_flash(socket, :error, "File not found")}
    end
  end

  def handle_event("close_manage_file", _params, socket) do
    {:noreply,
     socket
     |> assign(:active_file, nil)
     |> assign(:rename_target, nil)
     |> assign(:move_target, nil)}
  end

  def handle_event("open_manage_folder", %{"path" => path}, socket) do
    folder = Enum.find(socket.assigns.folders, &(&1.path == path))

    if folder do
      {:noreply,
       socket
       |> assign(:active_folder, folder)
       |> assign(:active_file, nil)
       |> assign(:context_menu, nil)}
    else
      {:noreply, put_flash(socket, :error, "Folder not found")}
    end
  end

  def handle_event("close_manage_folder", _params, socket) do
    {:noreply,
     socket
     |> assign(:active_folder, nil)
     |> assign(:rename_target, nil)
     |> assign(:move_target, nil)}
  end

  def handle_event("rename_file", %{"rename" => %{"id" => id, "name" => name}}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         {:ok, _file} <- Files.rename_file(user.id, file_id, name) do
      {:noreply,
       socket
       |> assign(:rename_target, nil)
       |> refresh_active_file(user.id, file_id)
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
         |> assign(:active_folder, nil)
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
     |> assign(:bulk_move_path, socket.assigns.current_folder)
     |> assign(:context_menu, nil)}
  end

  def handle_event("start_move", %{"type" => type, "path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:move_target, %{type: type, path: path})
     |> assign(:bulk_move_open, false)
     |> assign(:bulk_move_path, socket.assigns.current_folder)
     |> assign(:context_menu, nil)}
  end

  def handle_event("cancel_move", _params, socket) do
    {:noreply, assign(socket, :move_target, nil)}
  end

  def handle_event("toggle_tree_node", %{"path" => path}, socket) do
    expanded_paths = socket.assigns.tree_expanded_paths || MapSet.new()

    next_expanded_paths =
      if MapSet.member?(expanded_paths, path) do
        MapSet.delete(expanded_paths, path)
      else
        MapSet.put(expanded_paths, path)
      end

    all_folders = Files.list_folders(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:tree_expanded_paths, next_expanded_paths)
     |> assign(
       :folder_tree,
       build_folder_tree(all_folders, socket.assigns.current_folder, next_expanded_paths)
     )}
  end

  def handle_event("show_context_menu", params, socket) do
    x = parse_position(Map.get(params, "x"))
    y = parse_position(Map.get(params, "y"))

    context_menu = %{
      x: x,
      y: y,
      kind: Map.get(params, "kind"),
      token: Map.get(params, "token"),
      id: Map.get(params, "id"),
      path: Map.get(params, "path")
    }

    {:noreply, assign(socket, :context_menu, context_menu)}
  end

  def handle_event("hide_context_menu", _params, socket) do
    {:noreply, assign(socket, :context_menu, nil)}
  end

  def handle_event("context_action", %{"action" => action} = params, socket) do
    socket = assign(socket, :context_menu, nil)

    case {action, Map.get(params, "kind")} do
      {"open", "folder"} ->
        handle_event("open_folder", %{"path" => Map.get(params, "path", "")}, socket)

      {"open", "file"} ->
        handle_event("open_file", %{"id" => Map.get(params, "id", "")}, socket)

      {"manage", "folder"} ->
        handle_event("open_manage_folder", %{"path" => Map.get(params, "path", "")}, socket)

      {"manage", "file"} ->
        handle_event("open_manage_file", %{"id" => Map.get(params, "id", "")}, socket)

      {"rename", "folder"} ->
        handle_event(
          "start_rename",
          %{"type" => "folder", "path" => Map.get(params, "path", "")},
          socket
        )

      {"rename", "file"} ->
        handle_event(
          "start_rename",
          %{"type" => "file", "id" => Map.get(params, "id", "")},
          socket
        )

      {"move", "folder"} ->
        handle_event(
          "start_move",
          %{"type" => "folder", "path" => Map.get(params, "path", "")},
          socket
        )

      {"move", "file"} ->
        handle_event(
          "start_move",
          %{"type" => "file", "id" => Map.get(params, "id", "")},
          socket
        )

      {"delete", "folder"} ->
        handle_event("delete_folder", %{"path" => Map.get(params, "path", "")}, socket)

      {"delete", "file"} ->
        handle_event("delete_file", %{"id" => Map.get(params, "id", "")}, socket)

      {"new_folder", "blank"} ->
        handle_event("toggle_new_folder", %{}, socket)

      {"clear_selection", "blank"} ->
        handle_event("clear_selection", %{}, socket)

      {"refresh", "blank"} ->
        handle_event(
          "open_folder",
          %{"path" => Map.get(params, "path", socket.assigns.current_folder)},
          socket
        )

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("move_file", %{"move" => %{"id" => id, "folder" => folder}}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         {:ok, _file} <- Files.move_file(user.id, file_id, folder) do
      {:noreply,
       socket
       |> assign(:move_target, nil)
       |> refresh_active_file(user.id, file_id)
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
         |> assign(:active_folder, nil)
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

  def handle_event("set_selection", %{"tokens" => tokens}, socket) when is_list(tokens) do
    {:noreply, assign(socket, :selected_items, MapSet.new(tokens))}
  end

  def handle_event("set_selection", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_folder", %{"path" => path}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         files_path(
           path,
           socket.assigns.search_query,
           socket.assigns.sort_by,
           socket.assigns.active_filter
         )
     )}
  end

  def handle_event("open_file", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case parse_id(id) do
      {:ok, file_id} ->
        case Files.get_file(user.id, file_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "File not found")}

          file ->
            destination =
              if inline_viewable?(file.content_type) do
                ~p"/account/files/#{file.id}/preview"
              else
                ~p"/account/files/#{file.id}/download"
              end

            {:noreply, push_event(socket, "open_url", %{url: destination})}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid file")}
    end
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

  def handle_event("drag_move_items", %{"tokens" => tokens, "folder" => folder}, socket)
      when is_list(tokens) do
    user = socket.assigns.current_user

    case Files.bulk_move(user.id, tokens, folder) do
      :ok ->
        {:noreply,
         socket
         |> refresh_files(user.id, socket.assigns.current_folder)
         |> put_flash(:info, "Moved #{length(tokens)} item(s)")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not move dragged items")}
    end
  end

  def handle_event("drag_move_items", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("create_share", %{"share" => %{"file_id" => id} = params}, socket) do
    user = socket.assigns.current_user

    with {:ok, file_id} <- parse_id(id),
         {:ok, _share} <- Files.create_share(user.id, file_id, params) do
      {:noreply,
       socket
       |> refresh_active_file(user.id, file_id)
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
       |> refresh_active_file(
         user.id,
         socket.assigns.active_file && socket.assigns.active_file.id
       )
       |> refresh_files(user.id, socket.assigns.current_folder)
       |> put_flash(:info, "Share link revoked")}
    else
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not revoke share link")}
    end
  end

  defp refresh_files(socket, user_id, folder_path) do
    case Files.list_folder(user_id, folder_path, %{
           q: socket.assigns.search_query,
           sort: socket.assigns.sort_by,
           filter: socket.assigns.active_filter
         }) do
      {:ok, folder_view} -> apply_folder_view(socket, folder_view, user_id)
      {:error, _reason} -> socket
    end
  end

  defp refresh_active_file(socket, _user_id, nil), do: socket

  defp refresh_active_file(socket, user_id, file_id) do
    active_file = Enum.find(Files.list_files(user_id), &(&1.id == file_id))
    assign(socket, :active_file, active_file)
  end

  defp apply_folder_view(socket, folder_view, user_id) do
    all_folders = Files.list_folders(user_id)

    socket
    |> assign(:current_folder, folder_view.current_folder)
    |> assign(:folder_path, folder_view.current_folder)
    |> assign(:breadcrumbs, folder_view.breadcrumbs)
    |> assign(:folders, folder_view.folders)
    |> assign(:files, folder_view.files)
    |> assign(:search_query, folder_view.search_query)
    |> assign(:active_filter, folder_view.filter_by)
    |> assign(:sort_by, folder_view.sort_by)
    |> assign(:selected_items, MapSet.new())
    |> assign(:rename_target, nil)
    |> assign(:move_target, nil)
    |> assign(:bulk_move_open, false)
    |> assign(:bulk_move_path, folder_view.current_folder)
    |> assign(:show_new_folder_form, false)
    |> assign(
      :folder_tree,
      build_folder_tree(
        all_folders,
        folder_view.current_folder,
        socket.assigns.tree_expanded_paths || MapSet.new()
      )
    )
    |> assign(:context_menu, nil)
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

  defp build_folder_tree(folders, current_folder, tree_expanded_paths) do
    paths = folders |> Enum.map(& &1.path) |> Enum.sort()
    forced_expanded_paths = MapSet.new(folder_ancestors(current_folder))
    expanded_paths = MapSet.union(tree_expanded_paths, forced_expanded_paths)

    [%{path: "", name: "All files", depth: 0, has_children: true, expanded: true}] ++
      (paths
       |> Enum.map(fn path ->
         %{
           path: path,
           name: Path.basename(path),
           depth: folder_depth(path),
           has_children: Enum.any?(paths, &String.starts_with?(&1, path <> "/")),
           expanded: MapSet.member?(expanded_paths, path)
         }
       end)
       |> Enum.filter(fn node -> visible_tree_node?(node.path, expanded_paths) end))
  end

  defp folder_depth(""), do: 0

  defp folder_depth(path) do
    path |> String.split("/", trim: true) |> length()
  end

  defp folder_ancestors(""), do: []

  defp folder_ancestors(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce({[], ""}, fn segment, {paths, prefix} ->
      current = if prefix == "", do: segment, else: prefix <> "/" <> segment
      {paths ++ [current], current}
    end)
    |> elem(0)
  end

  defp folder_tree_item_class(current_folder, path) do
    cond do
      current_folder == path ->
        "border-primary/30 bg-primary/12 text-primary shadow-sm"

      path != "" and String.starts_with?(current_folder, path <> "/") ->
        "border-primary/15 bg-primary/6 text-primary/90"

      true ->
        "text-base-content/78 hover:border-base-300 hover:bg-base-200/70 hover:text-base-content"
    end
  end

  defp tree_toggle_class(true), do: "text-primary hover:bg-primary/10"
  defp tree_toggle_class(false), do: "text-base-content/45 hover:bg-base-200"

  defp tree_levels(depth) when depth > 0, do: Enum.to_list(1..depth)
  defp tree_levels(_depth), do: []

  defp visible_tree_node?(path, expanded_paths) do
    path
    |> folder_ancestors()
    |> Enum.drop(-1)
    |> Enum.all?(&MapSet.member?(expanded_paths, &1))
  end

  defp parse_position(value) do
    case Integer.parse(to_string(value || "0")) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp quick_filter_class(active_filter, value) do
    if active_filter == value do
      "bg-primary text-primary-content shadow-sm"
    else
      "bg-base-100 text-base-content/70 hover:bg-base-200"
    end
  end

  defp row_class(true), do: "bg-primary/8 ring-1 ring-primary/20"

  defp row_class(false), do: "hover:bg-base-200/45 focus-within:bg-base-200/45"

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

  defp storage_usage_percent(%{used_bytes: used, available_bytes: available})
       when is_integer(used) and is_integer(available) do
    total = used + available

    if total <= 0 do
      0
    else
      used
      |> Kernel./(total)
      |> Kernel.*(100)
      |> Float.round(1)
    end
  end

  defp storage_usage_percent(_), do: 0

  defp share_url(share), do: url(~p"/files/share/#{share.token}")
  defp share_password_protected?(share), do: Files.share_requires_password?(share)
  defp inline_viewable?(content_type), do: Files.inline_viewable_content_type?(content_type)

  defp image_preview?(content_type),
    do: is_binary(content_type) and String.starts_with?(content_type, "image/")

  defp files_path(folder, query, sort, filter) do
    normalized_sort = if sort == "updated_desc", do: nil, else: sort
    normalized_filter = if filter == "all", do: nil, else: filter

    params =
      [
        folder: blank_to_nil(folder),
        q: blank_to_nil(query),
        sort: blank_to_nil(normalized_sort),
        filter: blank_to_nil(normalized_filter)
      ]
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
