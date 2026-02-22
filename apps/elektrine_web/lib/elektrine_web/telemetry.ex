defmodule ElektrineWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [telemetry_poller: [measurements: periodic_measurements(), period: 30_000]]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration", unit: {:native, :millisecond}),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("elektrine.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("elektrine.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("elektrine.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("elektrine.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("elektrine.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),
      counter("oban.job.start.count", tags: [:queue, :worker]),
      counter("oban.job.stop.count", tags: [:queue, :worker]),
      counter("oban.job.exception.count", tags: [:queue, :worker]),
      summary("oban.job.stop.duration", unit: {:native, :millisecond}, tags: [:queue, :worker]),
      summary("oban.job.stop.queue_time", unit: {:native, :millisecond}, tags: [:queue]),
      counter("elektrine.mail.auth.count", tags: [:protocol, :outcome, :ratelimit]),
      summary("elektrine.mail.command.duration",
        unit: {:microsecond, :millisecond},
        tags: [:protocol, :command, :outcome]
      ),
      last_value("elektrine.mail.sessions.total", tags: [:protocol]),
      last_value("elektrine.mail.sessions.per_ip", tags: [:protocol]),
      counter("elektrine.auth.flow.count", tags: [:flow, :outcome, :reason]),
      counter("elektrine.email.inbound.count", tags: [:stage, :outcome, :reason, :source]),
      summary("elektrine.email.inbound.duration",
        unit: {:millisecond, :millisecond},
        tags: [:stage, :outcome, :source]
      ),
      counter("elektrine.email.outbound.count", tags: [:stage, :outcome, :reason, :route]),
      summary("elektrine.email.outbound.duration",
        unit: {:millisecond, :millisecond},
        tags: [:stage, :outcome, :route]
      ),
      counter("elektrine.federation.event.count", tags: [:component, :event, :outcome]),
      summary("elektrine.federation.event.duration",
        unit: {:millisecond, :millisecond},
        tags: [:component, :event, :outcome]
      ),
      counter("elektrine.cert.lifecycle.count", tags: [:component, :event, :outcome, :domain]),
      summary("elektrine.cert.lifecycle.duration",
        unit: {:millisecond, :millisecond},
        tags: [:component, :event, :outcome]
      ),
      last_value("elektrine.cert.status.expiring"),
      last_value("elektrine.cert.status.total"),
      counter("elektrine.upload.operation.count", tags: [:type, :outcome, :reason]),
      summary("elektrine.upload.operation.bytes",
        unit: {:byte, :kilobyte},
        tags: [:type, :outcome]
      ),
      counter("elektrine.cache.request.count", tags: [:cache, :op, :result]),
      counter("elektrine.api.request.count", tags: [:status_class, :endpoint_group, :method]),
      summary("elektrine.api.request.duration",
        unit: {:millisecond, :millisecond},
        tags: [:status_class, :endpoint_group]
      ),
      counter("elektrine.dav.request.count", tags: [:status_class, :endpoint_group, :method]),
      summary("elektrine.dav.request.duration",
        unit: {:millisecond, :millisecond},
        tags: [:status_class, :endpoint_group]
      )
    ]
  end

  defp periodic_measurements do
    [{__MODULE__, :measure_system_health, []}]
  end

  @doc "Measures system health indicators and logs warnings when overloaded.\n"
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
        require Logger

        Logger.warning(
          "[HEALTH] CPU overloaded: run_queue=#{run_queue} schedulers=#{scheduler_count} (#{Float.round(cpu_stress, 1)}x)"
        )

      oban_stats.available > 100 ->
        require Logger
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
        pool_timeout: 250,
        timeout: 5000
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
