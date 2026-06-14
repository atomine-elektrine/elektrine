defmodule Elektrine.Email.CustomDomainHealthWorker do
  @moduledoc false

  use Oban.Worker, queue: :email, max_attempts: 1

  alias Elektrine.Email

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Email.list_custom_domains_for_recheck(500)
    |> Enum.each(fn domain ->
      # Re-verifies the TXT + MX records and re-syncs DKIM as a side effect, so a
      # domain whose DNS records were removed is eventually demoted to pending.
      case Email.verify_custom_domain(domain) do
        {:ok, %{status: "verified"} = verified} ->
          _ = Email.check_deliverability_domain(verified.domain)

        _ ->
          :ok
      end
    end)

    :ok
  end
end
