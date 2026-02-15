defmodule Elektrine.CustomDomains.RenewalWorker do
  @moduledoc """
  Oban cron worker that checks for certificates needing renewal.

  Runs daily and queues renewal jobs for certificates expiring within 30 days.
  """

  use Oban.Worker,
    queue: :certificates,
    max_attempts: 1

  require Logger

  alias Elektrine.CustomDomains

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Checking for certificates needing renewal")

    domains = CustomDomains.get_domains_needing_renewal()
    count = length(domains)

    if count > 0 do
      Logger.info("Found #{count} certificates needing renewal")

      Enum.each(domains, fn domain ->
        Logger.info("Queuing renewal for #{domain.domain}")
        CustomDomains.queue_renewal(domain)
      end)
    end

    :ok
  end
end
