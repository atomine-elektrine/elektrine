defmodule Elektrine.Accounts.Muting do
  @moduledoc """
  User muting functionality.
  Handles muting, unmuting, and checking muted relationships between users.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Accounts.{User, UserMute}

  @doc """
  Mutes a user. If a mute already exists, updates notification muting preference.
  """
  def mute_user(muter_id, muted_id, mute_notifications \\ false) do
    case Repo.get_by(UserMute, muter_id: muter_id, muted_id: muted_id) do
      nil ->
        %UserMute{}
        |> UserMute.changeset(%{
          muter_id: muter_id,
          muted_id: muted_id,
          mute_notifications: mute_notifications
        })
        |> Repo.insert()

      mute ->
        mute
        |> UserMute.changeset(%{
          muter_id: muter_id,
          muted_id: muted_id,
          mute_notifications: mute_notifications
        })
        |> Repo.update()
    end
  end

  @doc """
  Unmutes a user.
  """
  def unmute_user(muter_id, muted_id) do
    case Repo.get_by(UserMute, muter_id: muter_id, muted_id: muted_id) do
      nil -> {:error, :not_muted}
      mute -> Repo.delete(mute)
    end
  end

  @doc """
  Checks if a user is muted by another user.
  """
  def user_muted?(muter_id, muted_id) do
    Repo.exists?(
      from(um in UserMute,
        where: um.muter_id == ^muter_id and um.muted_id == ^muted_id
      )
    )
  end

  @doc """
  Checks if notifications are muted for a muted user.
  """
  def user_muting_notifications?(muter_id, muted_id) do
    Repo.exists?(
      from(um in UserMute,
        where:
          um.muter_id == ^muter_id and um.muted_id == ^muted_id and
            um.mute_notifications == true
      )
    )
  end

  @doc """
  Gets all users muted by a user.
  """
  def list_muted_users(muter_id) do
    from(u in User,
      join: um in UserMute,
      on: um.muted_id == u.id,
      where: um.muter_id == ^muter_id,
      order_by: [desc: um.inserted_at],
      preload: [:profile]
    )
    |> Repo.all()
  end
end
