defmodule Elektrine.Accounts.Tracking do
  @moduledoc """
  User activity tracking functionality.
  Handles tracking of user logins, last seen timestamps, and email protocol access (IMAP/POP3).
  """

  use GenServer

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.User
  alias Elektrine.DB.WriteGuard
  alias Elektrine.Repo

  @last_seen_db_interval_seconds 5 * 60
  @last_seen_local_throttle_ms @last_seen_db_interval_seconds * 1000
  @last_seen_table :last_seen_update_throttle

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_last_seen_table()
    {:ok, %{}}
  end

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
    |> case do
      {:ok, updated_user} ->
        Elektrine.Accounts.TrustLevel.maybe_auto_promote_user(updated_user.id)
        {:ok, updated_user}

      error ->
        error
    end
  end

  @doc """
  Record IMAP access for a user.
  """
  def record_imap_access(user_id) do
    record_protocol_access(user_id, :last_imap_access, :imap)
  end

  @doc """
  Record POP3 access for a user.
  """
  def record_pop3_access(user_id) do
    record_protocol_access(user_id, :last_pop3_access, :pop3)
  end

  @doc """
  Update user's last_seen_at timestamp.
  Only updates if the last write attempt was more than 5 minutes ago to reduce database load.
  """
  def update_last_seen(user_id) do
    now_ms = System.monotonic_time(:millisecond)

    if allow_last_seen_update?(user_id, now_ms) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      cutoff = DateTime.add(now, -@last_seen_db_interval_seconds, :second)

      from(u in User,
        where: u.id == ^user_id and (is_nil(u.last_seen_at) or u.last_seen_at < ^cutoff)
      )
      |> Repo.update_all(set: [last_seen_at: now])
    else
      {0, nil}
    end
  end

  @doc """
  Update user's last_seen_at timestamp asynchronously.
  Delegates to update_last_seen/1 in a background task.
  """
  def update_last_seen_async(user_id) do
    update_last_seen(user_id)
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

  defp record_protocol_access(user_id, field, protocol) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    WriteGuard.run("#{protocol} access timestamp update for user_id=#{user_id}", fn ->
      from(u in User, where: u.id == ^user_id)
      |> Repo.update_all(set: [{field, now}])
    end)
  end

  defp allow_last_seen_update?(user_id, now_ms) when is_integer(user_id) do
    ensure_last_seen_table()

    try do
      case :ets.lookup(@last_seen_table, user_id) do
        [{^user_id, last_ms}] when now_ms - last_ms < @last_seen_local_throttle_ms ->
          false

        _ ->
          :ets.insert(@last_seen_table, {user_id, now_ms})
          true
      end
    rescue
      ArgumentError ->
        # If the supervised owner is still starting, recreate and retry once.
        ensure_last_seen_table()

        case :ets.lookup(@last_seen_table, user_id) do
          [{^user_id, last_ms}] when now_ms - last_ms < @last_seen_local_throttle_ms ->
            false

          _ ->
            :ets.insert(@last_seen_table, {user_id, now_ms})
            true
        end
    end
  end

  defp ensure_last_seen_table do
    case :ets.whereis(@last_seen_table) do
      :undefined ->
        try do
          :ets.new(@last_seen_table, [:named_table, :public, :set, {:write_concurrency, true}])
        rescue
          ArgumentError -> @last_seen_table
        end

      _ ->
        @last_seen_table
    end
  end
end
