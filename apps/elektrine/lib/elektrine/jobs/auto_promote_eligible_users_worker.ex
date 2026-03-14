defmodule Elektrine.Jobs.AutoPromoteEligibleUsersWorker do
  @moduledoc """
  Oban worker that auto-promotes users whose trust stats qualify them.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, count} = Elektrine.Accounts.TrustLevel.auto_promote_eligible_users()
    Logger.info("AutoPromoteEligibleUsersWorker: promoted #{count} user(s)")
    :ok
  end

  def enqueue do
    %{}
    |> new()
    |> Elektrine.JobQueue.insert()
  end
end
