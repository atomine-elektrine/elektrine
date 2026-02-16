defmodule Elektrine.CustomDomains.SSLConfig do
  @moduledoc """
  SSL configuration for dynamic certificate selection via SNI.

  This module provides the SNI callback function that Bandit/Erlang SSL uses
  to select the appropriate certificate based on the requested hostname.

  ## How It Works

  1. Client initiates TLS handshake with SNI (Server Name Indication)
  2. Erlang's SSL module calls `sni_fun` with the hostname
  3. We look up the certificate:
     - Main domains (elektrine.com, z.org) -> from disk
     - Subdomains of main domains -> parent domain certificate
  4. Return the certificate and key for the TLS handshake

  ## Configuration

  In runtime.exs, configure the endpoint with SNI:

      config :elektrine, ElektrineWeb.Endpoint,
        https: [
          port: 443,
          cipher_suite: :strong,
          certfile: "/path/to/default/cert.pem",
          keyfile: "/path/to/default/key.pem",
          sni_fun: &Elektrine.CustomDomains.SSLConfig.sni_fun/1
        ]
  """

  require Logger

  alias Elektrine.CustomDomains.MainDomainCerts

  @doc """
  SNI callback function for dynamic certificate selection.

  Called by Erlang's SSL module during TLS handshake.

  Returns SSL options for the hostname, or `:undefined` to use default certificate.
  """
  def sni_fun(hostname) when is_list(hostname) do
    sni_fun(to_string(hostname))
  end

  def sni_fun(hostname) when is_binary(hostname) do
    hostname_lower = String.downcase(hostname)

    cond do
      # Main domains - load from disk
      main_domain?(hostname_lower) ->
        load_main_domain_cert(hostname_lower)

      # Subdomains of main domains (*.z.org) - use z.org cert
      subdomain_of_main?(hostname_lower) ->
        parent = get_parent_domain(hostname_lower)
        load_main_domain_cert(parent)

      true ->
        Logger.debug("SNI: No certificate mapping for #{hostname_lower}, using default")
        :undefined
    end
  end

  defp load_main_domain_cert(domain) do
    case MainDomainCerts.get_certificate(domain) do
      {:ok, cert_der, {key_type, key_der}} ->
        Logger.debug("SNI: Loaded certificate for main domain #{domain}")
        [cert: cert_der, key: {key_type, key_der}]

      :error ->
        # Fallback to bootstrap certificate if main domain cert not ready
        load_bootstrap_cert(domain)
    end
  end

  defp load_bootstrap_cert(domain) do
    alias Elektrine.CustomDomains.BootstrapCerts

    case BootstrapCerts.ensure_bootstrap_cert() do
      {:ok, cert_path, key_path} ->
        with {:ok, cert_pem} <- File.read(cert_path),
             {:ok, key_pem} <- File.read(key_path),
             [{:Certificate, cert_der, _} | _] <- :public_key.pem_decode(cert_pem),
             [{key_type, key_der, _}] <- :public_key.pem_decode(key_pem) do
          Logger.debug("SNI: Using bootstrap certificate for #{domain} (real cert not ready)")
          [cert: cert_der, key: {key_type, key_der}]
        else
          _ ->
            Logger.warning("SNI: No certificate found for main domain #{domain}")
            :undefined
        end

      {:error, _reason} ->
        Logger.warning("SNI: No certificate found for main domain #{domain}")
        :undefined
    end
  end

  defp main_domain?(hostname) do
    hostname in MainDomainCerts.main_domains()
  end

  defp subdomain_of_main?(hostname) do
    Enum.any?(MainDomainCerts.main_domains(), fn domain ->
      String.ends_with?(hostname, "." <> domain)
    end)
  end

  defp get_parent_domain(hostname) do
    Enum.find(MainDomainCerts.main_domains(), fn domain ->
      String.ends_with?(hostname, "." <> domain)
    end)
  end

  @doc """
  Returns the default SSL options for the primary domain.
  """
  def default_ssl_options do
    primary_domain = List.first(MainDomainCerts.main_domains())
    cert_path = MainDomainCerts.cert_path(primary_domain)
    key_path = MainDomainCerts.key_path(primary_domain)

    if File.exists?(cert_path) && File.exists?(key_path) do
      [
        certfile: cert_path,
        keyfile: key_path,
        cipher_suite: :strong,
        sni_fun: &sni_fun/1
      ]
    else
      nil
    end
  end

  @doc """
  Checks if dynamic SSL is enabled and properly configured.
  """
  def enabled? do
    System.get_env("LETS_ENCRYPT_ENABLED") == "true"
  end
end
