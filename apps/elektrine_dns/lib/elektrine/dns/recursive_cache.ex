defmodule Elektrine.DNS.RecursiveCache do
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at, value}] ->
        if expires_at > System.monotonic_time(:millisecond) do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :error
        end

      _ ->
        :error
    end
  end

  def put(key, value, ttl_seconds) when ttl_seconds > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_seconds * 1000
    :ets.insert(@table, {key, expires_at, value})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
