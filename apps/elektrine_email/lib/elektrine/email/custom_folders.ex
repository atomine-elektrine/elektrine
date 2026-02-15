defmodule Elektrine.Email.CustomFolders do
  @moduledoc """
  Context module for managing custom email folders.
  """
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.Folder

  @max_folders_per_user 25

  @doc """
  Lists all folders for a user (flat list).
  """
  def list_folders(user_id) do
    Folder
    |> where(user_id: ^user_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Lists root folders (no parent) for a user.
  """
  def list_root_folders(user_id) do
    Folder
    |> where(user_id: ^user_id, parent_id: is_nil(nil))
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Gets a folder by ID for a user.
  """
  def get_folder(id, user_id) do
    Folder
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Gets a folder with its children preloaded.
  """
  def get_folder_with_children(id, user_id) do
    Folder
    |> where(id: ^id, user_id: ^user_id)
    |> preload(:children)
    |> Repo.one()
  end

  @doc """
  Creates a folder.
  """
  def create_folder(attrs) do
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    if count_folders(user_id) >= @max_folders_per_user do
      {:error, :limit_reached}
    else
      %Folder{}
      |> Folder.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a folder.
  """
  def update_folder(%Folder{} = folder, attrs) do
    folder
    |> Folder.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a folder.
  Messages in the folder will have their folder_id set to nil.
  """
  def delete_folder(%Folder{} = folder) do
    Repo.delete(folder)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking folder changes.
  """
  def change_folder(%Folder{} = folder, attrs \\ %{}) do
    Folder.changeset(folder, attrs)
  end

  @doc """
  Counts folders for a user.
  """
  def count_folders(user_id) do
    Folder
    |> where(user_id: ^user_id)
    |> select(count())
    |> Repo.one()
  end

  @doc """
  Moves a message to a folder.
  Accepts either a message struct or a message_id integer.
  """
  def move_message_to_folder(%Elektrine.Email.Message{} = message, folder_id) do
    move_message_to_folder(message.id, folder_id)
  end

  def move_message_to_folder(message_id, folder_id) when is_integer(message_id) do
    Elektrine.Email.update_message_flags(message_id, %{folder_id: folder_id})
  end

  @doc """
  Lists messages in a folder.
  """
  def list_folder_messages(folder_id, user_id, page \\ 1, per_page \\ 20) do
    folder = get_folder(folder_id, user_id)

    if folder do
      offset = (page - 1) * per_page

      messages =
        Elektrine.Email.Message
        |> where(folder_id: ^folder_id)
        |> where([m], m.deleted == false)
        |> order_by(desc: :inserted_at)
        |> limit(^per_page)
        |> offset(^offset)
        |> Repo.all()

      total =
        Elektrine.Email.Message
        |> where(folder_id: ^folder_id)
        |> where([m], m.deleted == false)
        |> select(count())
        |> Repo.one()

      %{
        messages: messages,
        total: total,
        page: page,
        per_page: per_page,
        has_next: offset + per_page < total,
        has_prev: page > 1
      }
    else
      %{messages: [], total: 0, page: page, per_page: per_page, has_next: false, has_prev: false}
    end
  end

  @doc """
  Gets folder hierarchy as a tree structure.
  """
  def get_folder_tree(user_id) do
    folders = list_folders(user_id)
    build_tree(folders, nil)
  end

  defp build_tree(folders, parent_id) do
    folders
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.map(fn folder ->
      %{
        folder: folder,
        children: build_tree(folders, folder.id)
      }
    end)
  end
end
