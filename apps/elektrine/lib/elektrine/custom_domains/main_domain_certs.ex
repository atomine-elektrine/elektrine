defmodule Elektrine.CustomDomains.MainDomainCerts do
  @moduledoc """
  Manages SSL certificates for main domains (elektrine.com, z.org).

  Certificates are stored on the persistent volume at /app/priv/certs/live/.

  This module handles:
  - Checking if certificates exist and are valid
  - Provisioning new certificates via Let's Encrypt
  - Loading certificates for SNI callback
  - Automatic renewal when certificates are expiring
  """

  require Logger

  alias Elektrine.CustomDomains.AcmeClient
  alias Elektrine.Telemetry.Events

  @main_domains ["elektrine.com", "z.org"]
  # Renew 30 days before expiry
  @renewal_threshold_days 30

  @doc """
  Returns the list of main domains that need certificates.
  """
  def main_domains, do: @main_domains

  @doc """
  Returns the base path for certificate storage.
  Configurable via :elektrine, :certs_base_path for testing.
  """
  def certs_base_path do
    base = Application.get_env(:elektrine, :certs_base_path, "/data/certs")
    Path.join(base, "live")
  end

  @doc """
  Ensures all main domain certificates exist and are valid.
  Called on application startup.
  """
  def ensure_certificates do
    Logger.info("Checking main domain certificates...")

    # Ensure base directory exists
    File.mkdir_p!(certs_base_path())

    statuses =
      Enum.map(@main_domains, fn domain ->
        status = check_certificate(domain)

        case status do
          :ok ->
            Logger.info("Certificate for #{domain} is valid")
            Events.cert(:main_domain_certs, :check, :valid, nil, %{domain: domain})

          :missing ->
            Logger.info("Certificate for #{domain} is missing, provisioning...")
            Events.cert(:main_domain_certs, :check, :missing, nil, %{domain: domain})
            provision_certificate(domain)

          :expiring ->
            Logger.info("Certificate for #{domain} is expiring soon, renewing...")
            Events.cert(:main_domain_certs, :check, :expiring, nil, %{domain: domain})
            provision_certificate(domain)

          {:error, reason} ->
            Logger.warning("Error checking certificate for #{domain}: #{inspect(reason)}")

            Events.cert(:main_domain_certs, :check, :failure, nil, %{
              domain: domain,
              reason: inspect(reason)
            })

            provision_certificate(domain)
        end

        status
      end)

    expiring_count =
      Enum.count(statuses, fn status ->
        status == :expiring or status == :missing or match?({:error, _}, status)
      end)

    Events.cert_status(expiring_count, length(@main_domains), %{component: :main_domain_certs})
  end

  @doc """
  Checks the status of a certificate for a domain.
  Returns :ok, :missing, :expiring, or {:error, reason}.
  """
  def check_certificate(domain) do
    cert_path = cert_path(domain)
    key_path = key_path(domain)

    if not File.exists?(cert_path) or not File.exists?(key_path) do
      :missing
    else
      case get_certificate_expiry(cert_path) do
        {:ok, expiry} ->
          days_until_expiry = DateTime.diff(expiry, DateTime.utc_now(), :day)

          if days_until_expiry < @renewal_threshold_days do
            :expiring
          else
            :ok
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Provisions a certificate for a main domain.
  """
  def provision_certificate(domain) do
    Logger.info("Provisioning certificate for #{domain}...")
    started_at = System.monotonic_time(:millisecond)

    case AcmeClient.provision_certificate(domain) do
      {:ok, cert_pem, key_pem, expires_at} ->
        # Save to disk
        domain_path = Path.join(certs_base_path(), domain)
        File.mkdir_p!(domain_path)

        cert_file = Path.join(domain_path, "fullchain.pem")
        key_file = Path.join(domain_path, "privkey.pem")

        File.write!(cert_file, cert_pem)
        File.write!(key_file, key_pem)

        Logger.info("Certificate for #{domain} provisioned successfully, expires: #{expires_at}")

        Events.cert(
          :main_domain_certs,
          :provision,
          :success,
          System.monotonic_time(:millisecond) - started_at,
          %{
            domain: domain,
            expires_at: DateTime.to_iso8601(expires_at)
          }
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to provision certificate for #{domain}: #{inspect(reason)}")

        Events.cert(
          :main_domain_certs,
          :provision,
          :failure,
          System.monotonic_time(:millisecond) - started_at,
          %{domain: domain, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Gets the certificate and key for a main domain (for SNI callback).
  Returns {:ok, cert_der, {key_type, key_der}} or :error.
  """
  def get_certificate(domain) do
    cert_path = cert_path(domain)
    key_path = key_path(domain)

    with {:ok, cert_pem} <- File.read(cert_path),
         {:ok, key_pem} <- File.read(key_path),
         {:ok, cert_der} <- parse_certificate(cert_pem),
         {:ok, key_info} <- parse_private_key(key_pem) do
      {:ok, cert_der, key_info}
    else
      _ -> :error
    end
  end

  @doc """
  Returns the certificate file path for a domain.
  """
  def cert_path(domain) do
    Path.join([certs_base_path(), domain, "fullchain.pem"])
  end

  @doc """
  Returns the private key file path for a domain.
  """
  def key_path(domain) do
    Path.join([certs_base_path(), domain, "privkey.pem"])
  end

  ## Private Functions

  defp get_certificate_expiry(cert_path) do
    with {:ok, cert_pem} <- File.read(cert_path),
         [{:Certificate, cert_der, _} | _] <- :public_key.pem_decode(cert_pem) do
      try do
        {:Certificate, {:TBSCertificate, _, _, _, _, _, validity, _, _, _, _, _}, _, _} =
          :public_key.der_decode(:Certificate, cert_der)

        {:Validity, _, {:utcTime, not_after}} = validity
        {:ok, parse_utc_time(to_string(not_after))}
      rescue
        e -> {:error, e}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_certificate}
    end
  end

  defp parse_utc_time(
         <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2),
           min::binary-size(2), ss::binary-size(2), "Z">>
       ) do
    year = String.to_integer(yy)
    year = if year >= 50, do: 1900 + year, else: 2000 + year

    {:ok, datetime} =
      NaiveDateTime.new(
        year,
        String.to_integer(mm),
        String.to_integer(dd),
        String.to_integer(hh),
        String.to_integer(min),
        String.to_integer(ss)
      )

    DateTime.from_naive!(datetime, "Etc/UTC")
  end

  defp parse_certificate(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, cert_der, _} | _] -> {:ok, cert_der}
      _ -> {:error, :invalid_certificate}
    end
  end

  defp parse_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:RSAPrivateKey, key_der, _}] ->
        {:ok, {:RSAPrivateKey, key_der}}

      [{:PrivateKeyInfo, key_der, _}] ->
        {:ok, {:PrivateKeyInfo, key_der}}

      [{type, key_der, _}] ->
        {:ok, {type, key_der}}

      _ ->
        {:error, :invalid_private_key}
    end
  end
end
