defmodule Elektrine.Messaging.FederationOutboxRetryWorker do
  @moduledoc """
  Periodically re-enqueues due messaging federation outbox rows.
  """

  use Oban.Worker,
    queue: :messaging_federation,
    max_attempts: 1

  alias Elektrine.Messaging.Federation

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Federation.enqueue_due_outbox_events(500)
    :ok
  end
end
