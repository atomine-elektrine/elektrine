defmodule ElektrineSocialWeb.TimelineLive.Operations.BookmarkFolderOperations do
  @moduledoc "Handles bookmark folder management and saved-item folder moves for the saved timeline view.\n"
  import Phoenix.LiveView
  import Phoenix.Component

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.SavedItem
  alias ElektrineSocialWeb.TimelineLive.Operations.Helpers

  def handle_event("select_bookmark_folder", params, socket) do
    folder_id = parse_folder_id(params["folder_id"])

    if folder_id == socket.assigns[:selected_bookmark_folder_id] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:selected_bookmark_folder_id, folder_id)
       |> reload_saved_view()}
    end
  end

  def handle_event("toggle_bookmark_folder_manager", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_bookmark_folder_manager, !socket.assigns[:show_bookmark_folder_manager])
     |> assign(:editing_bookmark_folder_id, nil)}
  end

  def handle_event("edit_bookmark_folder", %{"folder_id" => folder_id}, socket) do
    {:noreply, assign(socket, :editing_bookmark_folder_id, parse_folder_id(folder_id))}
  end

  def handle_event("cancel_edit_bookmark_folder", _params, socket) do
    {:noreply, assign(socket, :editing_bookmark_folder_id, nil)}
  end

  def handle_event("create_bookmark_folder", params, socket) do
    with_user(socket, fn user ->
      case Social.create_bookmark_folder(user.id, %{
             "name" => params["name"],
             "emoji" => params["emoji"]
           }) do
        {:ok, _folder} ->
          {:noreply,
           socket
           |> refresh_bookmark_folders()
           |> put_flash(:info, "Folder created")}

        {:error, changeset} ->
          {:noreply,
           put_flash(socket, :error, folder_error(changeset, "Failed to create folder"))}
      end
    end)
  end

  def handle_event("update_bookmark_folder", %{"folder_id" => folder_id} = params, socket) do
    with_user(socket, fn user ->
      with folder_id when not is_nil(folder_id) <- parse_folder_id(folder_id),
           folder when not is_nil(folder) <- Social.get_bookmark_folder(folder_id, user.id),
           {:ok, _updated} <-
             Social.update_bookmark_folder(folder, %{
               "name" => params["name"],
               "emoji" => params["emoji"]
             }) do
        {:noreply,
         socket
         |> assign(:editing_bookmark_folder_id, nil)
         |> refresh_bookmark_folders()
         |> put_flash(:info, "Folder updated")}
      else
        {:error, changeset} ->
          {:noreply,
           put_flash(socket, :error, folder_error(changeset, "Failed to rename folder"))}

        _ ->
          {:noreply, put_flash(socket, :error, "Folder not found")}
      end
    end)
  end

  def handle_event("delete_bookmark_folder", %{"folder_id" => folder_id}, socket) do
    with_user(socket, fn user ->
      with folder_id when not is_nil(folder_id) <- parse_folder_id(folder_id),
           {:ok, _folder} <- Social.delete_bookmark_folder(folder_id, user.id) do
        socket =
          socket
          |> assign(:editing_bookmark_folder_id, nil)
          |> refresh_bookmark_folders()
          |> put_flash(:info, "Folder deleted")

        if socket.assigns[:selected_bookmark_folder_id] == folder_id do
          {:noreply,
           socket
           |> assign(:selected_bookmark_folder_id, nil)
           |> reload_saved_view()}
        else
          {:noreply, socket}
        end
      else
        _ -> {:noreply, put_flash(socket, :error, "Folder not found")}
      end
    end)
  end

  def handle_event("move_saved_item", %{"message_id" => message_id} = params, socket) do
    with_user(socket, fn user ->
      message_id = parse_folder_id(message_id)
      folder_id = parse_folder_id(params["folder_id"])

      case message_id && move_saved_item(user.id, message_id, folder_id) do
        {:ok, _saved} ->
          socket =
            socket
            |> assign(
              :saved_item_folders,
              Map.put(socket.assigns[:saved_item_folders] || %{}, message_id, folder_id)
            )
            |> put_flash(:info, "Moved to #{folder_name(socket, folder_id)}")

          selected = socket.assigns[:selected_bookmark_folder_id]

          if selected && selected != folder_id do
            {:noreply, reload_saved_view(socket)}
          else
            {:noreply, Helpers.refresh_filtered_post(socket, message_id)}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to move saved item")}
      end
    end)
  end

  defp move_saved_item(user_id, message_id, nil) do
    case Repo.get_by(SavedItem, user_id: user_id, message_id: message_id) do
      nil ->
        {:error, :not_found}

      saved ->
        saved
        |> Ecto.Changeset.change(bookmark_folder_id: nil)
        |> Repo.update()
    end
  end

  defp move_saved_item(user_id, message_id, folder_id) do
    Social.save_post(user_id, message_id, bookmark_folder_id: folder_id)
  end

  defp refresh_bookmark_folders(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:bookmark_folders, Social.list_bookmark_folders(user.id))
    |> Helpers.refresh_filtered_posts_stream()
  end

  defp reload_saved_view(socket) do
    socket
    |> assign(:special_view_cache, %{})
    |> assign(:queued_posts, [])
    |> Helpers.queue_timeline_reload(
      socket.assigns.current_filter,
      socket.assigns.timeline_filter
    )
  end

  defp folder_name(_socket, nil), do: "All Saved"

  defp folder_name(socket, folder_id) do
    socket.assigns[:bookmark_folders]
    |> Kernel.||([])
    |> Enum.find_value("folder", fn folder ->
      if folder.id == folder_id, do: folder.name
    end)
  end

  defp parse_folder_id(value) when is_integer(value) and value > 0, do: value

  defp parse_folder_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_folder_id(_value), do: nil

  defp with_user(socket, fun) do
    case socket.assigns[:current_user] do
      nil -> {:noreply, put_flash(socket, :error, "You must be signed in")}
      user -> fun.(user)
    end
  end

  defp folder_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}, _fallback) do
    "Folder #{field} #{message}"
  end

  defp folder_error(_changeset, fallback), do: fallback
end
