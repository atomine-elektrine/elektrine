defmodule Elektrine.ActivityPub.DeliveryWorker do
  @moduledoc """
  Background worker for processing ActivityPub deliveries.
  Runs periodically to send queued activities to remote instances.
  """

  use GenServer
  require Logger

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Publisher

  # Run every 30 seconds (increased from 10 to reduce pool pressure)
  @tick_interval 30_000
  # Process fewer deliveries per tick to reduce pool pressure
  @batch_size 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("DeliveryWorker started")
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    process_deliveries()
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(:process_deliveries, state) do
    process_deliveries()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp process_deliveries do
    # Get pending deliveries with reduced batch size
    deliveries = ActivityPub.get_pending_deliveries(@batch_size)

    if deliveries != [] do
      Logger.info("Processing #{length(deliveries)} pending deliveries")

      # Process with small delay between each to avoid pool pressure
      Enum.each(deliveries, fn delivery ->
        process_delivery(delivery)
        # 100ms between deliveries
        Process.sleep(100)
      end)
    end
  end

  defp process_delivery(delivery) do
    activity = delivery.activity

    # Get the user who created the activity
    user =
      if activity.internal_user_id do
        Accounts.get_user!(activity.internal_user_id)
      else
        nil
      end

    if user do
      # Attempt delivery
      case Publisher.deliver(activity.data, user, delivery.inbox_url) do
        {:ok, :delivered} ->
          ActivityPub.mark_delivery_delivered(delivery.id)

        {:error, reason} ->
          ActivityPub.mark_delivery_failed(delivery.id, reason)
      end
    else
      # No user found, mark as failed
      ActivityPub.mark_delivery_failed(delivery.id, "User not found")
    end
  rescue
    e ->
      Logger.error("Error processing delivery #{delivery.id}: #{inspect(e)}")
      ActivityPub.mark_delivery_failed(delivery.id, inspect(e))
  end
end
