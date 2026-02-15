defmodule Elektrine.Admin do
  @moduledoc """
  The Admin context.
  Handles administrative functions like announcements and system management.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Admin.Announcement
  alias Elektrine.Admin.AnnouncementDismissal

  @doc """
  Returns the list of announcements.

  ## Examples

      iex> list_announcements()
      [%Announcement{}, ...]

  """
  def list_announcements do
    Announcement
    |> order_by([a], desc: a.inserted_at)
    |> preload([:created_by])
    |> Repo.all()
  end

  @doc """
  Returns the list of active announcements that should be displayed.
  Uses caching to reduce database queries.

  ## Examples

      iex> list_active_announcements()
      [%Announcement{}, ...]

  """
  def list_active_announcements do
    cache_key = :active_announcements

    case Cachex.get(:app_cache, cache_key) do
      {:ok, announcements} when not is_nil(announcements) ->
        announcements

      _ ->
        announcements = fetch_active_announcements()
        # Cache for 5 minutes
        Cachex.put(:app_cache, cache_key, announcements, ttl: :timer.minutes(5))
        announcements
    end
  end

  # Private function to fetch active announcements from database
  defp fetch_active_announcements do
    now = DateTime.utc_now()

    Announcement
    |> where([a], a.active == true)
    |> where([a], is_nil(a.starts_at) or a.starts_at <= ^now)
    |> where([a], is_nil(a.ends_at) or a.ends_at > ^now)
    |> order_by([a], [a.type, desc: a.inserted_at])
    |> preload([:created_by])
    |> Repo.all()
  end

  @doc """
  Returns active announcements for a specific user, excluding dismissed ones.
  Uses caching to reduce database queries.

  ## Examples

      iex> list_active_announcements_for_user(user_id)
      [%Announcement{}, ...]

  """
  def list_active_announcements_for_user(user_id) when is_integer(user_id) do
    cache_key = {:announcements, user_id}

    case Cachex.get(:app_cache, cache_key) do
      {:ok, announcements} when not is_nil(announcements) ->
        announcements

      _ ->
        announcements = fetch_active_announcements_for_user(user_id)
        # Cache for 5 minutes
        Cachex.put(:app_cache, cache_key, announcements, ttl: :timer.minutes(5))
        announcements
    end
  end

  def list_active_announcements_for_user(nil), do: list_active_announcements()

  # Private function to fetch announcements from database
  defp fetch_active_announcements_for_user(user_id) do
    now = DateTime.utc_now()

    Announcement
    |> where([a], a.active == true)
    |> where([a], is_nil(a.starts_at) or a.starts_at <= ^now)
    |> where([a], is_nil(a.ends_at) or a.ends_at > ^now)
    |> join(:left, [a], d in AnnouncementDismissal,
      on: d.announcement_id == a.id and d.user_id == ^user_id
    )
    |> where([a, d], is_nil(d.id))
    |> order_by([a], [a.type, desc: a.inserted_at])
    |> preload([:created_by])
    |> Repo.all()
  end

  @doc """
  Gets a single announcement.

  Raises `Ecto.NoResultsError` if the Announcement does not exist.

  ## Examples

      iex> get_announcement!(123)
      %Announcement{}

      iex> get_announcement!(456)
      ** (Ecto.NoResultsError)

  """
  def get_announcement!(id) do
    Announcement
    |> preload([:created_by])
    |> Repo.get!(id)
  end

  @doc """
  Creates a announcement.

  ## Examples

      iex> create_announcement(%{field: value})
      {:ok, %Announcement{}}

      iex> create_announcement(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_announcement(attrs \\ %{}) do
    result =
      %Announcement{}
      |> Announcement.changeset(attrs)
      |> Repo.insert()

    # Invalidate all user announcement caches
    case result do
      {:ok, _announcement} -> clear_all_announcement_caches()
      _ -> :ok
    end

    result
  end

  @doc """
  Updates a announcement.

  ## Examples

      iex> update_announcement(announcement, %{field: new_value})
      {:ok, %Announcement{}}

      iex> update_announcement(announcement, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_announcement(%Announcement{} = announcement, attrs) do
    result =
      announcement
      |> Announcement.changeset(attrs)
      |> Repo.update()

    # Invalidate all user announcement caches
    case result do
      {:ok, _announcement} -> clear_all_announcement_caches()
      _ -> :ok
    end

    result
  end

  @doc """
  Deletes a announcement.

  ## Examples

      iex> delete_announcement(announcement)
      {:ok, %Announcement{}}

      iex> delete_announcement(announcement)
      {:error, %Ecto.Changeset{}}

  """
  def delete_announcement(%Announcement{} = announcement) do
    result = Repo.delete(announcement)

    # Invalidate all user announcement caches
    case result do
      {:ok, _announcement} -> clear_all_announcement_caches()
      _ -> :ok
    end

    result
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking announcement changes.

  ## Examples

      iex> change_announcement(announcement)
      %Ecto.Changeset{data: %Announcement{}}

  """
  def change_announcement(%Announcement{} = announcement, attrs \\ %{}) do
    Announcement.changeset(announcement, attrs)
  end

  @doc """
  Deactivates expired announcements.
  This can be run as a scheduled task.
  """
  def deactivate_expired_announcements do
    now = DateTime.utc_now()

    {count, _} =
      Announcement
      |> where([a], a.active == true)
      |> where([a], not is_nil(a.ends_at) and a.ends_at <= ^now)
      |> Repo.update_all(set: [active: false, updated_at: now])

    count
  end

  @doc """
  Dismisses an announcement for a specific user.

  ## Examples

      iex> dismiss_announcement_for_user(user_id, announcement_id)
      {:ok, %AnnouncementDismissal{}}

  """
  def dismiss_announcement_for_user(user_id, announcement_id) do
    attrs = %{
      user_id: user_id,
      announcement_id: announcement_id,
      dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    result =
      %AnnouncementDismissal{}
      |> AnnouncementDismissal.changeset(attrs)
      |> Repo.insert()

    # Invalidate cache for this specific user
    case result do
      {:ok, _dismissal} -> Cachex.del(:app_cache, {:announcements, user_id})
      _ -> :ok
    end

    result
  end

  @doc """
  Checks if an announcement has been dismissed by a user.

  ## Examples

      iex> announcement_dismissed_by_user?(user_id, announcement_id)
      true

  """
  def announcement_dismissed_by_user?(user_id, announcement_id) do
    Repo.exists?(
      from d in AnnouncementDismissal,
        where: d.user_id == ^user_id and d.announcement_id == ^announcement_id
    )
  end

  # Private helper to clear all announcement caches
  # Clears all keys matching {:announcements, user_id} and :active_announcements
  defp clear_all_announcement_caches do
    # Clear the general active announcements cache
    Cachex.del(:app_cache, :active_announcements)

    # Get all keys from cache
    case Cachex.keys(:app_cache) do
      {:ok, keys} ->
        # Filter and delete user-specific announcement keys
        keys
        |> Enum.filter(fn
          {:announcements, _user_id} -> true
          _ -> false
        end)
        |> Enum.each(&Cachex.del(:app_cache, &1))

      _ ->
        :ok
    end
  end
end
