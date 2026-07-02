defmodule Elektrine.Accounts.Muting do
  @moduledoc """
  User muting functionality.
  Handles muting, unmuting, and checking muted relationships between users.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.{User, UserMute}
  alias Elektrine.Repo

  @doc """
  Mutes a user. If a mute already exists, updates notification muting preference.

  Pass a DateTime or a positive seconds integer as `expires_at` for temporary mutes.
  """
  def mute_user(muter_id, muted_id, mute_notifications \\ false, expires_at \\ nil) do
    expires_at = normalize_expires_at(expires_at)

    result =
      case Repo.get_by(UserMute, muter_id: muter_id, muted_id: muted_id) do
        nil ->
          %UserMute{}
          |> UserMute.changeset(%{
            muter_id: muter_id,
            muted_id: muted_id,
            mute_notifications: mute_notifications,
            expires_at: expires_at
          })
          |> Repo.insert()

        mute ->
          mute
          |> UserMute.changeset(%{
            muter_id: muter_id,
            muted_id: muted_id,
            mute_notifications: mute_notifications,
            expires_at: expires_at
          })
          |> Repo.update()
      end

    maybe_schedule_mute_expiration(result)
    notify_home_feed_policy_changed(muter_id, :muted_user)
    result
  end

  @doc """
  Unmutes a user.
  """
  def unmute_user(muter_id, muted_id) do
    result =
      case Repo.get_by(UserMute, muter_id: muter_id, muted_id: muted_id) do
        nil -> {:error, :not_muted}
        mute -> Repo.delete(mute)
      end

    notify_home_feed_policy_changed(muter_id, :unmuted_user)
    result
  end

  @doc """
  Checks if a user is muted by another user.
  """
  def user_muted?(muter_id, muted_id) do
    expire_due_mute(muter_id, muted_id)

    Repo.exists?(
      from(um in UserMute,
        where: um.muter_id == ^muter_id and um.muted_id == ^muted_id,
        where: is_nil(um.expires_at) or um.expires_at > ^Elektrine.Time.utc_now()
      )
    )
  end

  @doc """
  Checks if notifications are muted for a muted user.
  """
  def user_muting_notifications?(muter_id, muted_id) do
    expire_due_mute(muter_id, muted_id)

    Repo.exists?(
      from(um in UserMute,
        where:
          um.muter_id == ^muter_id and um.muted_id == ^muted_id and
            um.mute_notifications == true,
        where: is_nil(um.expires_at) or um.expires_at > ^Elektrine.Time.utc_now()
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
      where: is_nil(um.expires_at) or um.expires_at > ^Elektrine.Time.utc_now(),
      order_by: [desc: um.inserted_at],
      preload: [:profile]
    )
    |> Repo.all()
  end

  @doc """
  Removes all due expired mutes.
  """
  def expire_due_mutes(now \\ Elektrine.Time.utc_now()) do
    {count, _} =
      from(um in UserMute,
        where: not is_nil(um.expires_at) and um.expires_at <= ^now
      )
      |> Repo.delete_all()

    count
  end

  defp expire_due_mute(muter_id, muted_id) do
    from(um in UserMute,
      where: um.muter_id == ^muter_id and um.muted_id == ^muted_id,
      where: not is_nil(um.expires_at) and um.expires_at <= ^Elektrine.Time.utc_now()
    )
    |> Repo.delete_all()

    :ok
  end

  defp maybe_schedule_mute_expiration(
         {:ok, %UserMute{expires_at: %DateTime{} = expires_at} = mute}
       ) do
    _ = Elektrine.Accounts.MuteExpireWorker.enqueue(mute, expires_at)
    :ok
  end

  defp maybe_schedule_mute_expiration(_result), do: :ok

  defp normalize_expires_at(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)

  defp normalize_expires_at(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp normalize_expires_at(_), do: nil

  defp notify_home_feed_policy_changed(user_id, reason) when is_integer(user_id) do
    module = Module.concat([Elektrine, Social, HomeFeedInvalidationWorker])

    if Code.ensure_loaded?(module) do
      _ = module.clear_user(user_id, reason)
    end

    :ok
  rescue
    _ -> :ok
  end
end
