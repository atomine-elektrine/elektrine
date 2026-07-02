defmodule Elektrine.Social.EngagementCountRepairWorker do
  @moduledoc """
  Periodically reconciles cached social engagement counts with remote baselines.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 3_600,
      keys: [:limit, :batch_size],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Elektrine.Social.EngagementCountRepair

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = Map.get(args, "limit", 50_000)
    batch_size = Map.get(args, "batch_size", 500)

    result = EngagementCountRepair.run(limit: limit, batch_size: batch_size)

    Logger.info("EngagementCountRepairWorker repaired counters #{inspect(result)}")

    :ok
  end
end
