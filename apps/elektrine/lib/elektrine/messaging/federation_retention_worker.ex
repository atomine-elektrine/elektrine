defmodule Elektrine.Messaging.FederationRetentionWorker do
  @moduledoc """
  Daily retention/archival for messaging federation event and outbox tables.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias Elektrine.Messaging.Federation

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Federation.run_retention()
    :ok
  end
end
