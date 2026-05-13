defmodule Elektrine.Email.ExternalDeliveryMaintenanceWorker do
  @moduledoc false

  use Oban.Worker, queue: :email, max_attempts: 1

  alias Elektrine.Email.{ExternalDelivery, ExternalDeliveryAlerts, ExternalDeliveryMetricSnapshot}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    metrics = ExternalDelivery.operational_metrics()
    _ = ExternalDeliveryMetricSnapshot.create_from_metrics(metrics)
    _ = ExternalDeliveryAlerts.check_and_notify()
    _ = ExternalDelivery.requeue_stuck()

    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
    _ = ExternalDelivery.prune_attempts_older_than(cutoff)
    _ = ExternalDeliveryMetricSnapshot.prune_older_than(cutoff)

    :ok
  end
end
