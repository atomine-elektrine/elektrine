defmodule Elektrine.Encryption.KeyCache do
  @moduledoc """
  In-memory cache for derived encryption keys using ETS.
  Dramatically improves performance by avoiding repeated PBKDF2 computation.
  """

  use GenServer
  require Logger
  alias Elektrine.Telemetry.Events

  @table_name :encryption_key_cache
  # Keys expire after 24 hours
  @cache_ttl :timer.hours(24)

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Gets a cached key or derives and caches it.
  """
  def get_or_derive(user_id, derive_fun)
      when is_integer(user_id) and is_function(derive_fun, 0) do
    case :ets.lookup(@table_name, user_id) do
      [{^user_id, key, expires_at}] ->
        if System.system_time(:millisecond) < expires_at do
          # Cache hit - return cached key
          Events.cache(:encryption_key_cache, :get, :hit, %{scope: :key})
          key
        else
          # Expired - derive new key
          Events.cache(:encryption_key_cache, :get, :expired, %{scope: :key})
          derive_and_cache(user_id, derive_fun)
        end

      [] ->
        # Cache miss - derive new key
        Events.cache(:encryption_key_cache, :get, :miss, %{scope: :key})
        derive_and_cache(user_id, derive_fun)
    end
  end

  @doc """
  Invalidates cached key for a user (use when rotating keys).
  """
  def invalidate(user_id) do
    :ets.delete(@table_name, user_id)
    Events.cache(:encryption_key_cache, :delete, :ok, %{scope: :key})
  end

  @doc """
  Clears all cached keys.
  """
  def clear_all do
    :ets.delete_all_objects(@table_name)
    Events.cache(:encryption_key_cache, :clear, :ok, %{scope: :all})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with read concurrency for high-performance reads
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup of expired keys
    schedule_cleanup()

    Logger.info("Encryption key cache started")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove expired keys
    now = System.system_time(:millisecond)

    expired =
      :ets.select(@table_name, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table_name, &1))

    Events.cache(:encryption_key_cache, :cleanup, :ok, %{
      scope: :key,
      deleted_count: length(expired)
    })

    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp derive_and_cache(user_id, derive_fun) do
    # Derive the key (expensive operation)
    key = derive_fun.()

    # Cache it with expiration
    expires_at = System.system_time(:millisecond) + @cache_ttl
    :ets.insert(@table_name, {user_id, key, expires_at})
    Events.cache(:encryption_key_cache, :put, :ok, %{scope: :key})

    key
  end

  defp schedule_cleanup do
    # Clean up expired keys every hour
    Process.send_after(self(), :cleanup, :timer.hours(1))
  end
end
