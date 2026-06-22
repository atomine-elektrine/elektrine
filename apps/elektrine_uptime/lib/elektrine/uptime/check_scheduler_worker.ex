defmodule Elektrine.Uptime.CheckSchedulerWorker do
  @moduledoc """
  Cron worker (every minute) that fans out a `CheckWorker` job for each monitor
  that is due for a probe.

  Uses Oban `unique` on the per-monitor job so a slow probe can't pile up
  duplicate work across ticks.
  """
  use Oban.Worker, queue: :uptime, max_attempts: 1

  alias Elektrine.JobQueue
  alias Elektrine.Uptime
  alias Elektrine.Uptime.CheckWorker

  @impl Oban.Worker
  def perform(_job) do
    jobs =
      Uptime.list_due_monitors()
      |> Enum.map(fn monitor ->
        CheckWorker.new(%{"monitor_id" => monitor.id},
          unique: [
            period: 55,
            fields: [:args, :worker],
            states: [:available, :scheduled, :executing]
          ]
        )
      end)

    if jobs != [] do
      _ = JobQueue.insert_all(jobs)
    end

    :ok
  end
end
