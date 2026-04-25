defmodule Elektrine.DNS.QueryStatsBuffer do
  @moduledoc false

  use GenServer

  alias Elektrine.DNS.QueryStat
  alias Elektrine.Repo

  @flush_interval_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def increment(attrs) when is_map(attrs) do
    case Process.whereis(__MODULE__) do
      nil -> persist_batch(%{key(attrs) => {attrs, 1}})
      _pid -> GenServer.cast(__MODULE__, {:increment, attrs})
    end

    :ok
  end

  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :flush, 10_000)
    end
  end

  @impl true
  def init(_opts) do
    schedule_flush()
    {:ok, %{counts: %{}}}
  end

  @impl true
  def handle_cast({:increment, attrs}, state) do
    counts =
      Map.update(state.counts, key(attrs), {attrs, 1}, fn {existing_attrs, count} ->
        {existing_attrs, count + 1}
      end)

    {:noreply, %{state | counts: counts}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    persist_batch(state.counts)
    {:reply, :ok, %{state | counts: %{}}}
  end

  @impl true
  def handle_info(:flush, state) do
    persist_batch(state.counts)
    schedule_flush()
    {:noreply, %{state | counts: %{}}}
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp persist_batch(counts) when map_size(counts) == 0, do: :ok

  defp persist_batch(counts) do
    Enum.each(counts, fn {_key, {attrs, count}} ->
      %QueryStat{}
      |> QueryStat.changeset(Map.put(attrs, :query_count, count))
      |> Repo.insert(
        on_conflict: [inc: [query_count: count]],
        conflict_target: [:zone_id, :query_hour, :qname, :qtype, :rcode, :transport],
        returning: false
      )
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp key(attrs) do
    {
      attrs.zone_id,
      attrs.query_date,
      attrs.query_hour,
      attrs.qname,
      attrs.qtype,
      attrs.rcode,
      attrs.transport
    }
  end
end
