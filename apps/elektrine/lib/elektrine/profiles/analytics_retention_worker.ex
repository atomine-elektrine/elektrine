defmodule Elektrine.Profiles.AnalyticsRetentionWorker do
  @moduledoc """
  Prunes raw analytics rows after the configured retention windows.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, priority: 9

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    counts = Elektrine.Profiles.prune_analytics_retention()
    Logger.info("Pruned raw analytics rows: #{inspect(counts)}")

    :ok
  end
end
