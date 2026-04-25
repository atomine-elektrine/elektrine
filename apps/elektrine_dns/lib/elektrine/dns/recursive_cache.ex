defmodule Elektrine.DNS.RecursiveCache do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @cleanup_interval_ms 60_000

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
    trim_if_needed()
    :ok
  end

  def put(_key, _value, _ttl_seconds), do: :ok

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    sweep_expired()
    trim_to_limit(max_entries())
    schedule_cleanup()
    {:noreply, state}
  end

  defp trim_if_needed do
    max_entries = max_entries()

    if :ets.info(@table, :size) > max_entries do
      sweep_expired()
      trim_to_limit(max_entries)
    end
  end

  defp sweep_expired do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :"$1", :_}, [{:<, :"$1", now}], [true]}
    ])
  end

  defp trim_to_limit(max_entries) do
    size = :ets.info(@table, :size)

    if size > max_entries do
      delete_count = size - max_entries

      case :ets.select(@table, [{{:"$1", :_, :_}, [], [:"$1"]}], delete_count) do
        {keys, _continuation} -> Enum.each(keys, &:ets.delete(@table, &1))
        :"$end_of_table" -> :ok
      end
    end
  end

  defp max_entries do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_cache_max_entries, 10_000)
    |> max(1)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, cleanup_interval_ms())
  end

  defp cleanup_interval_ms do
    Application.get_env(:elektrine, :dns, [])
    |> Keyword.get(:recursive_cache_cleanup_interval_ms, @cleanup_interval_ms)
    |> max(1)
  end
end
