defmodule Elektrine.CustomDomains.ProvisioningWorker do
  @moduledoc """
  Oban worker for provisioning SSL certificates for custom domains.

  Handles:
  - Initial certificate provisioning after domain verification
  - Certificate renewal before expiry
  """

  use Oban.Worker,
    queue: :certificates,
    max_attempts: 3,
    priority: 1

  require Logger

  alias Elektrine.CustomDomains
  alias Elektrine.CustomDomains.AcmeClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain_id" => domain_id} = args}) do
    action = Map.get(args, "action", "provision")
    domain = CustomDomains.get_domain!(domain_id)

    Logger.info("#{action} certificate for domain: #{domain.domain}")

    if System.get_env("LETS_ENCRYPT_ENABLED") != "true" do
      Logger.info("ProvisioningWorker: LETS_ENCRYPT_ENABLED is not true; skipping ACME job")
      :ok
    else
      case action do
        "provision" -> provision_certificate(domain)
        "renewal" -> renew_certificate(domain)
        _ -> {:error, :unknown_action}
      end
    end
  end

  defp provision_certificate(domain) do
    case AcmeClient.provision_certificate(domain.domain) do
      {:ok, cert_pem, key_pem, expires_at} ->
        case CustomDomains.store_certificate(domain, cert_pem, key_pem, expires_at) do
          {:ok, _updated_domain} ->
            Logger.info("Certificate provisioned and stored for #{domain.domain}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to store certificate for #{domain.domain}: #{inspect(reason)}")

            CustomDomains.mark_ssl_failed(
              domain,
              "Failed to store certificate: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Certificate provisioning failed for #{domain.domain}: #{inspect(reason)}")
        CustomDomains.mark_ssl_failed(domain, inspect(reason))
        {:error, reason}
    end
  end

  defp renew_certificate(domain) do
    # Same flow as provisioning - ACME handles renewal transparently
    provision_certificate(domain)
  end
end
