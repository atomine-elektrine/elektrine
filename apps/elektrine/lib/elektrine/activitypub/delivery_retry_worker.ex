defmodule Elektrine.ActivityPub.DeliveryRetryWorker do
  @moduledoc """
  Periodically re-enqueues pending federation deliveries that are due for retry.
  """

  use Oban.Worker,
    queue: :activitypub_delivery,
    max_attempts: 1

  alias Elektrine.ActivityPub

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    delivery_ids = ActivityPub.get_retryable_delivery_ids(500)

    if delivery_ids != [] do
      ActivityPub.ActivityDeliveryWorker.enqueue_many(delivery_ids)
    end

    :ok
  end
end
