defmodule ElektrineWeb.TelemetryMeasurements do
  @moduledoc false

  require Logger

  @doc false
  def measure_system_health do
    scheduler_count = :erlang.system_info(:schedulers_online)
    run_queue = :erlang.statistics(:run_queue)
    cpu_stress = run_queue / scheduler_count
    oban_stats = get_oban_queue_stats()

    :telemetry.execute(
      [:elektrine, :system, :health],
      %{
        cpu_stress: cpu_stress,
        run_queue: run_queue,
        scheduler_count: scheduler_count,
        oban_available: oban_stats.available,
        oban_executing: oban_stats.executing,
        oban_scheduled: oban_stats.scheduled
      },
      %{}
    )

    cond do
      cpu_stress > 2.0 ->
        Logger.warning(
          "[HEALTH] CPU overloaded: run_queue=#{run_queue} schedulers=#{scheduler_count} (#{Float.round(cpu_stress, 1)}x)"
        )

      oban_stats.available > 100 ->
        Logger.warning("[HEALTH] Oban backlog: #{oban_stats.available} jobs waiting")

      true ->
        :ok
    end
  end

  defp get_oban_queue_stats do
    import Ecto.Query

    counts =
      Elektrine.Repo.all(
        from(j in "oban_jobs",
          where: j.state in ["available", "executing", "scheduled"],
          group_by: j.state,
          select: {j.state, count(j.id)}
        ),
        pool_timeout: 150,
        timeout: 750
      )
      |> Enum.into(%{})

    %{
      available: Map.get(counts, "available", 0),
      executing: Map.get(counts, "executing", 0),
      scheduled: Map.get(counts, "scheduled", 0)
    }
  rescue
    _ -> %{available: 0, executing: 0, scheduled: 0}
  end
end
