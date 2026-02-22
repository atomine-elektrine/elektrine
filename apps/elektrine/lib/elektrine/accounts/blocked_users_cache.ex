defmodule Elektrine.Accounts.BlockedUsersCache do
  @moduledoc """
  Cached blocked users lookup to avoid repeated database queries.
  """

  import Ecto.Query
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @cache_ttl :timer.minutes(5)

  @doc """
  Gets all user IDs that are blocked (both ways) for a given user.
  Cached for 5 minutes to avoid repeated queries on every feed load.
  """
  def get_all_blocked_user_ids(user_id) do
    case Cachex.get(:blocked_users_cache, cache_key(user_id)) do
      {:ok, nil} ->
        # Cache miss - fetch from database
        blocked_ids = fetch_blocked_ids(user_id)
        Cachex.put(:blocked_users_cache, cache_key(user_id), blocked_ids, ttl: @cache_ttl)
        blocked_ids

      {:ok, blocked_ids} ->
        # Cache hit
        blocked_ids

      {:error, _} ->
        # Cache error - fetch directly
        fetch_blocked_ids(user_id)
    end
  end

  @doc """
  Invalidates the blocked users cache for a user.
  Call this when a user blocks/unblocks someone.
  """
  def invalidate(user_id) do
    Cachex.del(:blocked_users_cache, cache_key(user_id))
  end

  defp cache_key(user_id), do: "blocked_#{user_id}"

  defp fetch_blocked_ids(user_id) do
    # Single optimized query to get all blocked user IDs (both directions)
    from(u in User,
      left_join: b1 in "user_blocks",
      on: b1.blocker_id == ^user_id and b1.blocked_id == u.id,
      left_join: b2 in "user_blocks",
      on: b2.blocked_id == ^user_id and b2.blocker_id == u.id,
      where: not is_nil(b1.id) or not is_nil(b2.id),
      select: u.id
    )
    |> Repo.all()
  end
end
