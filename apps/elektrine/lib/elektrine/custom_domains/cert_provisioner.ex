defmodule Elektrine.CustomDomains.CertProvisioner do
  @moduledoc """
  GenServer that provisions SSL certificates for main domains on startup.

  This runs before the Phoenix endpoint starts to ensure certificates are
  available for TLS termination. It also periodically checks for renewal.

  ## Bootstrap Strategy

  1. First, generate a self-signed bootstrap cert (always succeeds)
  2. Then, attempt to provision real certs via Let's Encrypt
  3. If real cert provisioning fails, the bootstrap cert allows HTTPS to work
  4. SNI callback will serve real certs once available

  This ensures the app always starts, even if Let's Encrypt is rate-limited.
  """

  use GenServer

  require Logger

  alias Elektrine.CustomDomains.MainDomainCerts
  alias Elektrine.CustomDomains.BootstrapCerts
  alias Elektrine.Telemetry.Events

  # Check for renewal every 12 hours
  @renewal_check_interval :timer.hours(12)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Only provision in production with LETS_ENCRYPT_ENABLED
    if should_provision?() do
      Events.cert(:cert_provisioner, :startup, :enabled, nil, %{})

      # Step 1: Ensure bootstrap cert exists (never fails)
      # This allows the HTTPS listener to start even if real certs aren't ready
      Logger.info("CertProvisioner: Ensuring bootstrap certificate exists...")
      BootstrapCerts.ensure_bootstrap_cert()

      # Step 2: Try to provision real certs (may fail gracefully)
      # We do this async after a short delay to not block startup
      # The endpoint can start with bootstrap cert, SNI will serve real certs when ready
      Process.send_after(self(), :provision_real_certs, 5_000)

      # Schedule periodic renewal checks
      schedule_renewal_check()
    else
      Logger.info("CertProvisioner: SSL provisioning disabled (dev/test mode)")
      Events.cert(:cert_provisioner, :startup, :disabled, nil, %{})
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:provision_real_certs, state) do
    Logger.info("CertProvisioner: Provisioning real certificates...")
    started_at = System.monotonic_time(:millisecond)

    # Try to provision real certs - failures are logged but don't crash
    try do
      MainDomainCerts.ensure_certificates()

      Events.cert(
        :cert_provisioner,
        :provision_real_certs,
        :success,
        System.monotonic_time(:millisecond) - started_at,
        %{}
      )
    rescue
      e ->
        Logger.error("CertProvisioner: Failed to provision certificates: #{inspect(e)}")

        Events.cert(
          :cert_provisioner,
          :provision_real_certs,
          :failure,
          System.monotonic_time(:millisecond) - started_at,
          %{reason: inspect(e)}
        )

        Logger.warning(
          "CertProvisioner: HTTPS will use bootstrap cert until real certs are ready"
        )

        # Retry in 5 minutes
        Process.send_after(self(), :provision_real_certs, :timer.minutes(5))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:check_renewal, state) do
    Logger.info("CertProvisioner: Checking for certificate renewals...")
    started_at = System.monotonic_time(:millisecond)

    domains = MainDomainCerts.main_domains()
    total_count = length(domains)

    expiring_count =
      Enum.reduce(domains, 0, fn domain, expiring_total ->
        case MainDomainCerts.check_certificate(domain) do
          :expiring ->
            Logger.info("CertProvisioner: Renewing certificate for #{domain}")

            case MainDomainCerts.provision_certificate(domain) do
              :ok ->
                Events.cert(:cert_provisioner, :renew, :success, nil, %{domain: domain})

              {:error, reason} ->
                Events.cert(:cert_provisioner, :renew, :failure, nil, %{
                  domain: domain,
                  reason: inspect(reason)
                })
            end

            expiring_total + 1

          :ok ->
            expiring_total

          :missing ->
            Events.cert(:cert_provisioner, :check, :missing, nil, %{domain: domain})
            expiring_total

          {:error, reason} ->
            Events.cert(:cert_provisioner, :check, :failure, nil, %{
              domain: domain,
              reason: inspect(reason)
            })

            expiring_total
        end
      end)

    Events.cert_status(expiring_count, total_count, %{component: :cert_provisioner})

    Events.cert(
      :cert_provisioner,
      :check_renewal,
      :success,
      System.monotonic_time(:millisecond) - started_at,
      %{}
    )

    schedule_renewal_check()
    {:noreply, state}
  end

  defp schedule_renewal_check do
    Process.send_after(self(), :check_renewal, @renewal_check_interval)
  end

  defp should_provision? do
    System.get_env("LETS_ENCRYPT_ENABLED") == "true"
  end
end
