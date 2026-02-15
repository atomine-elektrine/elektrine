defmodule Elektrine.Accounts.Tracking do
  @moduledoc """
  User activity tracking functionality.
  Handles tracking of user logins, last seen timestamps, and email protocol access (IMAP/POP3).
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Accounts.User

  @doc """
  Update user login information (IP address, login time, login count).
  """
  def update_user_login_info(user, ip_address) do
    login_count = (user.login_count || 0) + 1

    user
    |> User.login_changeset(%{
      last_login_ip: ip_address,
      last_login_at: DateTime.utc_now() |> DateTime.truncate(:second),
      login_count: login_count
    })
    |> Repo.update()
  end

  @doc """
  Record IMAP access for a user.
  """
  def record_imap_access(user_id) do
    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [last_imap_access: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  @doc """
  Record POP3 access for a user.
  """
  def record_pop3_access(user_id) do
    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [last_pop3_access: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  @doc """
  Update user's last_seen_at timestamp.
  Only updates if last update was more than 60 seconds ago to reduce database load.
  """
  def update_last_seen(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(now, -60, :second)

    from(u in User,
      where: u.id == ^user_id and (is_nil(u.last_seen_at) or u.last_seen_at < ^cutoff)
    )
    |> Repo.update_all(set: [last_seen_at: now])
  end

  @doc """
  Update user's last_seen_at timestamp asynchronously.
  Delegates to update_last_seen/1 in a background task.
  """
  def update_last_seen_async(user_id) do
    Task.start(fn -> update_last_seen(user_id) end)
    :ok
  end

  @doc """
  Updates user status (online, away, dnd, offline).
  """
  def update_user_status(%User{} = user, status, message \\ nil)
      when status in ["online", "away", "dnd", "offline"] do
    # Sanitize status message - trim and limit length
    sanitized_message =
      if message && is_binary(message) do
        message
        |> String.trim()
        # Max 100 characters
        |> String.slice(0, 100)
        |> case do
          "" -> nil
          msg -> msg
        end
      else
        nil
      end

    attrs = %{
      status: status,
      status_message: sanitized_message,
      status_updated_at: DateTime.utc_now()
    }

    user
    |> Ecto.Changeset.cast(attrs, [:status, :status_message, :status_updated_at])
    |> Ecto.Changeset.validate_required([:status])
    |> Ecto.Changeset.validate_inclusion(:status, ["online", "away", "dnd", "offline"])
    |> Ecto.Changeset.validate_length(:status_message, max: 100)
    |> Repo.update()
  end

  @doc """
  Gets user status information.
  """
  def get_user_status(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        {:ok,
         %{status: user.status, message: user.status_message, updated_at: user.status_updated_at}}
    end
  end
end
