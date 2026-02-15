defmodule Elektrine.ActivityPub.DeliveryCleanup do
  @moduledoc """
  Background job that cleans up old failed deliveries from the database.
  Runs daily to prevent the delivery queue from growing indefinitely.
  """

  use GenServer
  require Logger

  # 24 hours
  @cleanup_interval 24 * 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Schedule first cleanup after 1 hour
    schedule_cleanup(60 * 60 * 1000)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.info("DeliveryCleanup: Starting cleanup of old failed deliveries...")

    try do
      count = Elektrine.ActivityPub.cleanup_old_deliveries()
      Logger.info("DeliveryCleanup: Deleted #{count} old failed deliveries")
    rescue
      e ->
        Logger.error("DeliveryCleanup: Error during cleanup: #{inspect(e)}")
    end

    # Schedule next cleanup
    schedule_cleanup(@cleanup_interval)
    {:noreply, state}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end
end
