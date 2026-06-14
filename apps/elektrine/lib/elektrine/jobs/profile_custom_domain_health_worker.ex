defmodule Elektrine.Jobs.ProfileCustomDomainHealthWorker do
  @moduledoc """
  Periodically re-verifies the DNS records backing custom profile domains so a
  domain whose records were removed is eventually demoted back to pending.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Elektrine.Profiles

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Profiles.list_custom_domains_for_recheck(500)
    |> Enum.each(fn domain -> _ = Profiles.verify_custom_domain(domain) end)

    :ok
  end
end
