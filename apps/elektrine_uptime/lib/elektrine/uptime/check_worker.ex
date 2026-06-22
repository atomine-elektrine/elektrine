defmodule Elektrine.Uptime.CheckWorker do
  @moduledoc """
  Probes a single monitor: runs the configured `Checker`, records the result
  (driving incident transitions), and broadcasts the result over PubSub.

  `max_attempts: 1` — the next scheduler tick is the retry, so a transient
  failure doesn't block the queue.
  """
  use Oban.Worker, queue: :uptime, max_attempts: 1

  require Logger

  alias Elektrine.Uptime

  @default_checker Elektrine.Uptime.Checker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"monitor_id" => monitor_id}}) do
    case Uptime.get_monitor!(monitor_id) do
      %{enabled: false} ->
        :ok

      monitor ->
        checker = Application.get_env(:elektrine_uptime, :checker, @default_checker)
        result = checker.run(monitor)

        case Uptime.record_check(monitor, result) do
          {:ok, %{monitor: updated_monitor, check: check, transition: transition}} ->
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "uptime:monitor:#{monitor_id}",
              {:uptime_check, updated_monitor, check}
            )

            Elektrine.Uptime.Notifier.notify(updated_monitor, check, transition)

            :ok

          {:error, reason} ->
            Logger.error(
              "uptime check failed to record for monitor #{monitor_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  rescue
    Ecto.NoResultsError ->
      # Monitor was deleted between scheduling and execution.
      :ok
  end
end
