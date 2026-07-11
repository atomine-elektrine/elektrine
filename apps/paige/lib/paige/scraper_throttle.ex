defmodule Paige.ScraperThrottle do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def acquire(source, min_interval_ms) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:acquire, source, normalize_interval(min_interval_ms)})
    else
      :ok
    end
  end

  def block(source, seconds) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:block, source, normalize_seconds(seconds)})
    else
      :ok
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:acquire, source, min_interval_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)
    source_state = Map.get(state, source, %{last_started_at: nil, blocked_until: nil})

    cond do
      is_integer(source_state.blocked_until) and source_state.blocked_until > now ->
        retry_after = ceil((source_state.blocked_until - now) / 1_000)
        {:reply, {:error, {:blocked, retry_after}}, state}

      is_integer(source_state.last_started_at) and
          now - source_state.last_started_at < min_interval_ms ->
        retry_after = min_interval_ms - (now - source_state.last_started_at)
        {:reply, {:error, {:throttled, retry_after}}, state}

      true ->
        next_source_state = %{last_started_at: now, blocked_until: nil}
        {:reply, :ok, Map.put(state, source, next_source_state)}
    end
  end

  @impl true
  def handle_call({:block, source, seconds}, _from, state) do
    now = System.monotonic_time(:millisecond)
    source_state = Map.get(state, source, %{last_started_at: nil, blocked_until: nil})
    next_source_state = %{source_state | blocked_until: now + seconds * 1_000}
    {:reply, :ok, Map.put(state, source, next_source_state)}
  end

  defp normalize_interval(value) when is_integer(value), do: value |> max(0) |> min(60_000)
  defp normalize_interval(_value), do: 1_000
  defp normalize_seconds(value) when is_integer(value), do: value |> max(1) |> min(86_400)
  defp normalize_seconds(_value), do: 300
end
