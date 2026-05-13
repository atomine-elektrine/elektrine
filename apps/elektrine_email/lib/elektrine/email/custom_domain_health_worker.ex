defmodule Elektrine.Email.CustomDomainHealthWorker do
  @moduledoc false

  use Oban.Worker, queue: :email, max_attempts: 1

  alias Elektrine.Email

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{recent_domains: domains} = Email.custom_domain_admin_stats(500)

    domains
    |> Enum.filter(&(&1.status == "verified"))
    |> Enum.each(fn domain ->
      _ = Email.sync_custom_domain_dkim(domain)
      _ = Email.check_deliverability_domain(domain.domain)
    end)

    :ok
  end
end
