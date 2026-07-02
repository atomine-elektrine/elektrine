defmodule ElektrineWeb.API.BookmarkFolderController do
  @moduledoc """
  Pleroma-compatible bookmark folder API.
  """
  use ElektrineWeb, :controller

  action_fallback ElektrineWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    folders =
      bookmark_folders().list_folders(user.id)
      |> Enum.map(&format_folder/1)

    json(conn, folders)
  end

  def create(conn, params) do
    user = conn.assigns[:current_user]

    case bookmark_folders().create_folder(user.id, params) do
      {:ok, folder} ->
        conn
        |> put_status(:created)
        |> json(format_folder(folder))

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with folder when not is_nil(folder) <- bookmark_folders().get_folder(id, user.id),
         {:ok, updated} <- bookmark_folders().update_folder(folder, params) do
      json(conn, format_folder(updated))
    else
      nil -> not_found(conn)
      {:error, changeset} -> changeset_error(conn, changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case bookmark_folders().delete_folder(id, user.id) do
      {:ok, folder} -> json(conn, %{id: to_string(folder.id), deleted: true})
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp format_folder(folder) do
    %{
      id: to_string(folder.id),
      name: folder.name,
      emoji: folder.emoji
    }
  end

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp bookmark_folders, do: Module.concat([Elektrine, Social, BookmarkFolders])
end
