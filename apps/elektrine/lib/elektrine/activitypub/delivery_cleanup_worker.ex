defmodule Elektrine.ActivityPub.DeliveryCleanupWorker do
  @moduledoc """
  Oban worker for cleaning up old failed ActivityPub deliveries.

  Scheduled via Oban Cron to run daily. Replaces the old DeliveryCleanup GenServer.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  alias Elektrine.ActivityPub

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("DeliveryCleanupWorker: Starting cleanup of old failed deliveries...")

    count = ActivityPub.cleanup_old_deliveries()
    Logger.info("DeliveryCleanupWorker: Deleted #{count} old failed deliveries")

    :ok
  rescue
    e ->
      Logger.error("DeliveryCleanupWorker: Error during cleanup: #{inspect(e)}")
      {:error, inspect(e)}
  end

  @doc """
  Manually enqueue a cleanup job (for testing or manual triggering).
  """
  def enqueue do
    %{}
    |> new()
    |> Oban.insert()
  end
end
