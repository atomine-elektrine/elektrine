defmodule Elektrine.JobQueueMonitor do
  @moduledoc """
  Lightweight in-memory Oban telemetry monitor.

  This is intentionally process-local. It is for live operational visibility,
  not historical analytics.
  """

  use GenServer

  @initial_state %{
    processed_jobs: 0,
    queues: %{},
    workers: %{},
    federation: %{
      queue_depth: 0,
      skipped_jobs: 0,
      skipped_by_component: %{}
    },
    home_feed: %{
      fanout_insert: 0,
      fanout_remove: 0,
      cache_hit: 0,
      cache_miss: 0,
      last_cache_size: 0
    },
    reports: %{}
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, @initial_state, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> @initial_state
  end

  @impl GenServer
  def init(state) do
    :telemetry.attach_many(
      "#{__MODULE__}-oban",
      [
        [:oban, :job, :stop],
        [:oban, :job, :exception],
        [:elektrine, :federation, :queue_depth],
        [:elektrine, :federation, :load_guard, :skip],
        [:elektrine, :home_feed, :fanout],
        [:elektrine, :home_feed, :cache],
        [:elektrine, :reports, :operation]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, state}
  end

  def handle_event([:oban, :job, event], measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:job_event, event_status(event), measurements, metadata})
  catch
    :exit, _ -> :ok
  end

  def handle_event([:elektrine, :federation, :queue_depth], measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:federation_queue_depth, measurements, metadata})
  catch
    :exit, _ -> :ok
  end

  def handle_event([:elektrine, :federation, :load_guard, :skip], measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:federation_skip, measurements, metadata})
  catch
    :exit, _ -> :ok
  end

  def handle_event([:elektrine, :home_feed, event], measurements, metadata, _config)
      when event in [:fanout, :cache] do
    GenServer.cast(__MODULE__, {:home_feed_event, event, measurements, metadata})
  catch
    :exit, _ -> :ok
  end

  def handle_event([:elektrine, :reports, :operation], measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:report_event, measurements, metadata})
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_cast({:job_event, status, measurements, metadata}, state) do
    queue = metadata_value(metadata, :queue) || "unknown"
    worker = metadata_value(metadata, :worker) || "unknown"
    op = operation(metadata)
    duration = Map.get(measurements, :duration, 0)

    state =
      state
      |> Map.update!(:processed_jobs, &(&1 + 1))
      |> update_in([:queues], &increment_bucket(&1, queue, status, duration))
      |> update_in([:workers], &increment_worker(&1, worker, op, status, duration))

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:federation_queue_depth, measurements, _metadata}, state) do
    depth = Map.get(measurements, :jobs, 0)
    {:noreply, put_in(state, [:federation, :queue_depth], depth)}
  end

  def handle_cast({:federation_skip, measurements, metadata}, state) do
    count = Map.get(measurements, :count, 1)
    component = metadata_value(metadata, :component) || "unknown"

    state =
      state
      |> update_in([:federation, :skipped_jobs], &(&1 + count))
      |> update_in([:federation, :skipped_by_component], fn buckets ->
        Map.update(buckets, component, count, &(&1 + count))
      end)

    {:noreply, state}
  end

  def handle_cast({:home_feed_event, :fanout, measurements, metadata}, state) do
    count = Map.get(measurements, :count, 1)

    key =
      case metadata_value(metadata, :operation) do
        "remove" -> :fanout_remove
        :remove -> :fanout_remove
        _ -> :fanout_insert
      end

    {:noreply, update_in(state, [:home_feed, key], &(&1 + count))}
  end

  def handle_cast({:home_feed_event, :cache, measurements, metadata}, state) do
    count = Map.get(measurements, :count, 1)
    size = Map.get(measurements, :size, 0)

    key =
      case metadata_value(metadata, :result) do
        "hit" -> :cache_hit
        :hit -> :cache_hit
        _ -> :cache_miss
      end

    state =
      state
      |> update_in([:home_feed, key], &(&1 + count))
      |> put_in([:home_feed, :last_cache_size], size)

    {:noreply, state}
  end

  def handle_cast({:report_event, measurements, metadata}, state) do
    count = Map.get(measurements, :count, 1)
    operation = metadata_value(metadata, :operation) || "unknown"
    outcome = metadata_value(metadata, :outcome) || "unknown"
    key = "#{operation}:#{outcome}"

    {:noreply,
     update_in(state, [:reports], &Map.update(&1, key, count, fn value -> value + count end))}
  end

  defp event_status(:stop), do: :success
  defp event_status(:exception), do: :failure
  defp event_status(_), do: :unknown

  defp increment_bucket(buckets, key, status, duration) do
    bucket =
      buckets
      |> Map.get(key, empty_bucket())
      |> increment_status(status, duration)

    Map.put(buckets, key, bucket)
  end

  defp increment_worker(workers, worker, op, status, duration) do
    worker_stats = Map.get(workers, worker, %{})
    Map.put(workers, worker, increment_bucket(worker_stats, op, status, duration))
  end

  defp increment_status(bucket, status, duration) do
    bucket
    |> Map.update!(:processed_jobs, &(&1 + 1))
    |> Map.update!(status, &(&1 + 1))
    |> Map.update!(:duration_native, &(&1 + duration))
  end

  defp empty_bucket do
    %{processed_jobs: 0, success: 0, failure: 0, unknown: 0, duration_native: 0}
  end

  defp operation(metadata) do
    args = metadata_value(metadata, :args) || %{}
    Map.get(args, "op") || Map.get(args, :op) || Map.get(args, "type") || "perform"
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
