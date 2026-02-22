defmodule Elektrine.Updates do
  @moduledoc """
  Manages platform updates and changelog entries.
  """

  import Ecto.Query
  alias Elektrine.PlatformUpdate
  alias Elektrine.Repo

  @doc """
  Gets the latest updates for display on the homepage.
  Returns a list of update entries with title, date, description, and badge.
  """
  def get_latest_updates do
    PlatformUpdate
    |> where([u], u.published == true)
    |> order_by([u], desc: u.inserted_at)
    |> limit(3)
    |> Repo.all()
    |> Enum.map(&format_update/1)
  end

  @doc """
  Gets all updates (for admin management).
  """
  def get_all_updates do
    PlatformUpdate
    |> order_by([u], desc: u.inserted_at)
    |> Repo.all()
    |> Enum.map(&format_update/1)
  end

  @doc """
  Creates a new update entry.
  """
  def create_update(attrs) do
    %PlatformUpdate{}
    |> PlatformUpdate.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing update entry.
  """
  def update_update(%PlatformUpdate{} = update, attrs) do
    update
    |> PlatformUpdate.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an update entry.
  """
  def delete_update(%PlatformUpdate{} = update) do
    Repo.delete(update)
  end

  @doc """
  Gets a single update by id.
  """
  def get_update!(id), do: Repo.get!(PlatformUpdate, id)

  @doc """
  Gets a changeset for creating a new update.
  """
  def change_update(%PlatformUpdate{} = update, attrs \\ %{}) do
    PlatformUpdate.changeset(update, attrs)
  end

  # Format database record for display
  defp format_update(update) do
    %{
      id: update.id,
      title: update.title,
      date: Calendar.strftime(update.inserted_at, "%b %-d, %Y"),
      badge: update.badge,
      description: update.description,
      items: update.items,
      published: update.published,
      created_by_id: update.created_by_id
    }
  end
end
