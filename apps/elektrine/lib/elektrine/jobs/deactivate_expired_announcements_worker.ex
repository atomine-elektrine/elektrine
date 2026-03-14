defmodule Elektrine.Jobs.DeactivateExpiredAnnouncementsWorker do
  @moduledoc """
  Oban worker that deactivates expired announcements.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    count = Elektrine.Admin.deactivate_expired_announcements()
    Logger.info("DeactivateExpiredAnnouncementsWorker: deactivated #{count} announcement(s)")
    :ok
  end

  def enqueue do
    %{}
    |> new()
    |> Elektrine.JobQueue.insert()
  end
end
