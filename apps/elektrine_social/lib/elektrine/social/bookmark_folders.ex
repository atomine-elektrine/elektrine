defmodule Elektrine.Social.BookmarkFolders do
  @moduledoc """
  Owned bookmark folders for saved posts.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Repo
  alias Elektrine.Social.BookmarkFolder

  def list_folders(user_id) do
    from(f in BookmarkFolder,
      where: f.user_id == ^user_id,
      order_by: [asc: f.name, asc: f.id]
    )
    |> Repo.all()
  end

  def get_folder(id, user_id) do
    Repo.get_by(BookmarkFolder, id: id, user_id: user_id)
  end

  def folder_belongs_to_user?(nil, _user_id), do: true
  def folder_belongs_to_user?("", _user_id), do: true

  def folder_belongs_to_user?(folder_id, user_id) do
    Repo.exists?(
      from(f in BookmarkFolder,
        where: f.id == ^folder_id and f.user_id == ^user_id
      )
    )
  end

  def create_folder(user_id, attrs) when is_map(attrs) do
    %BookmarkFolder{}
    |> BookmarkFolder.changeset(normalize_attrs(attrs, user_id))
    |> Repo.insert()
  end

  def update_folder(%BookmarkFolder{} = folder, attrs) when is_map(attrs) do
    folder
    |> BookmarkFolder.changeset(Map.drop(normalize_attrs(attrs, folder.user_id), [:user_id]))
    |> Repo.update()
  end

  def delete_folder(%BookmarkFolder{} = folder), do: Repo.delete(folder)

  def delete_folder(id, user_id) do
    case get_folder(id, user_id) do
      nil -> {:error, :not_found}
      folder -> delete_folder(folder)
    end
  end

  defp normalize_attrs(attrs, user_id) do
    %{
      user_id: user_id,
      name: attrs["name"] || attrs[:name],
      emoji: attrs["emoji"] || attrs[:emoji]
    }
  end
end
