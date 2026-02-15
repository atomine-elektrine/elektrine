defmodule Elektrine.CustomDomains.BootstrapCerts do
  @moduledoc """
  Generates self-signed bootstrap certificates for initial app startup.

  When the app starts with LETS_ENCRYPT_ENABLED=true but no certificates exist yet,
  this module generates temporary self-signed certificates so the HTTPS listener
  can start. The SNI callback will then serve real certificates once provisioned.

  ## How It Works

  1. On startup, check if primary domain certs exist
  2. If not, generate self-signed certs as placeholders
  3. Start HTTPS listener with self-signed certs
  4. Background task provisions real certs via Let's Encrypt
  5. SNI callback returns real certs when available, falling back to self-signed

  The self-signed certs will cause browser warnings, but:
  - ACME challenges work (they're over HTTP)
  - Once real certs are provisioned, SNI serves them
  - Users may see brief SSL warning during initial setup
  """

  require Logger

  # Allow configurable paths for testing
  defp certs_base_path do
    Application.get_env(:elektrine, :certs_base_path, "/data/certs")
  end

  defp bootstrap_cert_path do
    Path.join([certs_base_path(), "bootstrap", "cert.pem"])
  end

  defp bootstrap_key_path do
    Path.join([certs_base_path(), "bootstrap", "key.pem"])
  end

  @doc """
  Ensures certificates exist for the HTTPS listener to start.
  Returns paths to cert and key files (real or self-signed bootstrap).
  """
  def ensure_certs_exist(domain) do
    base_path = certs_base_path()
    real_cert = Path.join([base_path, "live", domain, "fullchain.pem"])
    real_key = Path.join([base_path, "live", domain, "privkey.pem"])

    if File.exists?(real_cert) && File.exists?(real_key) do
      Logger.info("Using existing certificate for #{domain}")
      {:ok, real_cert, real_key}
    else
      Logger.warning("No certificate for #{domain}, using bootstrap self-signed cert")
      ensure_bootstrap_cert()
    end
  end

  @doc """
  Returns paths to bootstrap certificates, creating them if needed.
  """
  def ensure_bootstrap_cert do
    cert_path = bootstrap_cert_path()
    key_path = bootstrap_key_path()

    if File.exists?(cert_path) && File.exists?(key_path) do
      {:ok, cert_path, key_path}
    else
      generate_bootstrap_cert()
    end
  end

  @doc """
  Generates a self-signed certificate for bootstrap purposes.
  Valid for 1 year, uses a generic CN.
  Uses OpenSSL command line for reliable certificate generation.
  """
  def generate_bootstrap_cert do
    Logger.info("Generating self-signed bootstrap certificate...")

    cert_path = bootstrap_cert_path()
    key_path = bootstrap_key_path()

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(cert_path))

    # Use OpenSSL to generate a self-signed certificate
    # This is more reliable than manual ASN.1 encoding
    {output, exit_code} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-keyout",
          key_path,
          "-out",
          cert_path,
          "-days",
          "365",
          "-nodes",
          "-subj",
          "/CN=localhost/O=Elektrine"
        ],
        stderr_to_stdout: true
      )

    case exit_code do
      0 ->
        Logger.info("Bootstrap certificate generated successfully")
        {:ok, cert_path, key_path}

      _ ->
        Logger.error("Failed to generate bootstrap certificate: #{output}")
        {:error, :openssl_failed}
    end
  end
end
