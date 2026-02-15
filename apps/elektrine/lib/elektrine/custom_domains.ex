defmodule Elektrine.CustomDomains do
  @moduledoc """
  Context for managing custom domains for user profiles and email.

  Users can point their own domains (e.g., john.com) to their z.org profile.
  The system handles:

  1. Domain ownership verification via DNS TXT record
  2. SSL certificate provisioning via Let's Encrypt ACME
  3. Certificate renewal before expiry
  4. Request routing to the correct user profile
  5. Email support with DKIM signing and custom domain addresses
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.CustomDomains.CustomDomain
  alias Elektrine.CustomDomains.CustomDomainAddress
  alias Elektrine.CustomDomains.DKIM
  alias Elektrine.CustomDomains.DNSVerification

  # Maximum domains per user (can be increased for premium users)
  @max_domains_per_user 1

  # Certificate renewal threshold (days before expiry)
  @renewal_threshold_days 30

  ## Domain Management

  @doc """
  Adds a new custom domain for a user.

  Returns `{:ok, domain}` or `{:error, changeset}`.
  """
  def add_domain(user_id, domain) do
    # Check domain limit
    current_count = count_user_domains(user_id)

    if current_count >= @max_domains_per_user do
      {:error, :domain_limit_reached}
    else
      %CustomDomain{}
      |> CustomDomain.create_changeset(%{domain: domain, user_id: user_id})
      |> Repo.insert()
    end
  end

  @doc """
  Gets a custom domain by its hostname.
  """
  def get_domain(domain) when is_binary(domain) do
    domain_lower = String.downcase(domain)

    CustomDomain
    |> where([d], d.domain == ^domain_lower)
    |> preload(:user)
    |> Repo.one()
  end

  @doc """
  Gets a custom domain by ID.
  """
  def get_domain!(id) do
    CustomDomain
    |> preload(:user)
    |> Repo.get!(id)
  end

  @doc """
  Gets an active custom domain by hostname (for request routing).

  Only returns domains with status "active" and valid SSL.
  """
  def get_active_domain(hostname) when is_binary(hostname) do
    hostname_lower = String.downcase(hostname)

    CustomDomain
    |> where([d], d.domain == ^hostname_lower)
    |> where([d], d.status == "active")
    |> where([d], d.ssl_status == "issued")
    |> preload(:user)
    |> Repo.one()
  end

  @doc """
  Gets all custom domains for a user.
  """
  def list_user_domains(user_id) do
    CustomDomain
    |> where([d], d.user_id == ^user_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Counts domains for a user.
  """
  def count_user_domains(user_id) do
    CustomDomain
    |> where([d], d.user_id == ^user_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Deletes a custom domain.
  """
  def delete_domain(%CustomDomain{} = domain) do
    # Clear from certificate cache
    Elektrine.CustomDomains.CertificateCache.delete(domain.domain)
    Repo.delete(domain)
  end

  @doc """
  Deletes a custom domain by ID for a specific user.
  """
  def delete_domain(user_id, domain_id) do
    case Repo.get_by(CustomDomain, id: domain_id, user_id: user_id) do
      nil -> {:error, :not_found}
      domain -> delete_domain(domain)
    end
  end

  ## Verification

  @doc """
  Gets verification instructions for a domain.
  """
  def get_verification_instructions(%CustomDomain{} = domain) do
    %{
      dns_record: %{
        type: "TXT",
        name: "_elektrine",
        value: "elektrine-verify=#{domain.verification_token}"
      },
      a_record: %{
        type: "A",
        name: "@",
        value: get_server_ip()
      },
      full_txt_hostname: "_elektrine.#{domain.domain}"
    }
  end

  @doc """
  Attempts to verify domain ownership via DNS TXT record.
  """
  def verify_domain(%CustomDomain{} = domain) do
    case Elektrine.CustomDomains.DNSVerification.verify(domain.domain, domain.verification_token) do
      :ok ->
        domain
        |> CustomDomain.verification_changeset(%{
          status: "verified",
          verified_at: DateTime.utc_now(),
          last_error: nil
        })
        |> Repo.update()

      {:error, reason} ->
        error_message =
          case reason do
            :no_record -> "DNS TXT record not found"
            :token_mismatch -> "DNS TXT record found but token doesn't match"
            :dns_error -> "DNS lookup failed"
            _ -> "Verification failed: #{inspect(reason)}"
          end

        domain
        |> CustomDomain.verification_changeset(%{
          last_error: error_message,
          error_count: (domain.error_count || 0) + 1
        })
        |> Repo.update()

        {:error, reason}
    end
  end

  @doc """
  Checks if a domain is verified.
  """
  def verified?(%CustomDomain{status: status}) do
    status in ["verified", "provisioning_ssl", "active"]
  end

  ## SSL Certificate Management

  @doc """
  Initiates SSL certificate provisioning for a verified domain.
  """
  def provision_ssl(%CustomDomain{status: "verified"} = domain) do
    # Update status to provisioning
    {:ok, domain} =
      domain
      |> CustomDomain.acme_challenge_changeset(%{
        status: "provisioning_ssl",
        ssl_status: "provisioning"
      })
      |> Repo.update()

    # Queue the ACME provisioning job only when Let's Encrypt is enabled.
    # In test/dev environments we skip this to avoid network calls and noisy failures.
    if lets_encrypt_enabled?() do
      %{domain_id: domain.id}
      |> Elektrine.CustomDomains.ProvisioningWorker.new()
      |> Oban.insert()
    end

    {:ok, domain}
  end

  def provision_ssl(%CustomDomain{} = _domain) do
    {:error, :not_verified}
  end

  @doc """
  Stores ACME challenge data for HTTP-01 verification.
  """
  def store_acme_challenge(%CustomDomain{} = domain, token, response) do
    domain
    |> CustomDomain.acme_challenge_changeset(%{
      acme_challenge_token: token,
      acme_challenge_response: response
    })
    |> Repo.update()
  end

  @doc """
  Gets ACME challenge response by token (for HTTP-01 challenge endpoint).
  """
  def get_acme_challenge_response(token) do
    CustomDomain
    |> where([d], d.acme_challenge_token == ^token)
    |> select([d], d.acme_challenge_response)
    |> Repo.one()
  end

  defp lets_encrypt_enabled? do
    System.get_env("LETS_ENCRYPT_ENABLED") == "true"
  end

  @doc """
  Stores SSL certificate after successful ACME provisioning.

  Certificate and private key are encrypted before storage.
  """
  def store_certificate(%CustomDomain{} = domain, certificate_pem, private_key_pem, expires_at) do
    # Encrypt certificate and private key using system key
    encrypted_cert = encrypt_system(certificate_pem)
    encrypted_key = encrypt_system(private_key_pem)

    result =
      domain
      |> CustomDomain.certificate_changeset(%{
        certificate: encrypted_cert,
        private_key: encrypted_key,
        certificate_expires_at: expires_at,
        certificate_issued_at: DateTime.utc_now(),
        ssl_status: "issued",
        status: "active",
        last_error: nil,
        error_count: 0,
        # Clear challenge data
        acme_challenge_token: nil,
        acme_challenge_response: nil
      })
      |> Repo.update()

    case result do
      {:ok, updated_domain} ->
        # Add to certificate cache
        Elektrine.CustomDomains.CertificateCache.put(
          updated_domain.domain,
          certificate_pem,
          private_key_pem
        )

        {:ok, updated_domain}

      error ->
        error
    end
  end

  @doc """
  Gets decrypted certificate and private key for a domain.
  """
  def get_certificate(%CustomDomain{certificate: cert, private_key: key})
      when is_binary(cert) and is_binary(key) do
    with {:ok, decrypted_cert} <- decrypt_system(cert),
         {:ok, decrypted_key} <- decrypt_system(key) do
      {:ok, decrypted_cert, decrypted_key}
    else
      _ -> {:error, :decryption_failed}
    end
  end

  def get_certificate(_), do: {:error, :no_certificate}

  ## System-level encryption for certificates
  # Uses the master secret directly instead of per-user keys

  @aad "elektrine_certificates_v1"

  defp encrypt_system(plaintext) when is_binary(plaintext) do
    key = get_system_encryption_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    # Combine iv + tag + ciphertext for storage
    iv <> tag <> ciphertext
  end

  defp decrypt_system(encrypted) when is_binary(encrypted) do
    key = get_system_encryption_key()

    # Extract iv (12 bytes) + tag (16 bytes) + ciphertext
    <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> = encrypted

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  rescue
    _ -> {:error, :decryption_failed}
  end

  defp get_system_encryption_key do
    master_secret = Application.get_env(:elektrine, :encryption_master_secret)
    salt = "certificate_encryption_salt"

    # Derive a 32-byte key from master secret
    :crypto.pbkdf2_hmac(:sha256, master_secret, salt, 100_000, 32)
  end

  @doc """
  Gets certificate by domain name (loads from DB if not in cache).
  """
  def get_certificate_for_domain(hostname) do
    case get_active_domain(hostname) do
      nil ->
        {:error, :not_found}

      domain ->
        get_certificate(domain)
    end
  end

  @doc """
  Marks SSL provisioning as failed.
  """
  def mark_ssl_failed(%CustomDomain{} = domain, error) do
    domain
    |> CustomDomain.ssl_error_changeset(error)
    |> Repo.update()
  end

  ## Certificate Renewal

  @doc """
  Gets domains that need certificate renewal.
  """
  def get_domains_needing_renewal do
    threshold = DateTime.utc_now() |> DateTime.add(@renewal_threshold_days * 24 * 60 * 60)

    CustomDomain
    |> where([d], d.status == "active")
    |> where([d], d.ssl_status == "issued")
    |> where([d], d.certificate_expires_at < ^threshold)
    |> Repo.all()
  end

  @doc """
  Queues certificate renewal for a domain.
  """
  def queue_renewal(%CustomDomain{} = domain) do
    %{domain_id: domain.id, action: "renewal"}
    |> Elektrine.CustomDomains.ProvisioningWorker.new()
    |> Oban.insert()
  end

  ## Email Support

  @doc """
  Enables email for a custom domain.

  This generates DKIM keys and sets up the domain for email sending/receiving.
  The user must then configure DNS records before email will work.
  """
  def enable_email(%CustomDomain{status: "active"} = domain) do
    # Generate DKIM key pair
    case DKIM.generate_key_pair() do
      {:ok, %{private_key: private_pem, public_key: public_b64, selector: selector}} ->
        # Encrypt the private key before storage
        encrypted_private = encrypt_system(private_pem)

        domain
        |> CustomDomain.enable_email_changeset(%{
          email_enabled: true,
          dkim_private_key: encrypted_private,
          dkim_public_key: public_b64,
          dkim_selector: selector
        })
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enable_email(%CustomDomain{}) do
    {:error, :domain_not_active}
  end

  @doc """
  Disables email for a custom domain.
  """
  def disable_email(%CustomDomain{} = domain) do
    domain
    |> Ecto.Changeset.change(%{
      email_enabled: false,
      mx_verified: false,
      spf_verified: false,
      dkim_verified: false,
      dmarc_verified: false,
      email_dns_verified_at: nil
    })
    |> Repo.update()
  end

  @doc """
  Verifies email DNS records for a custom domain.

  Checks MX, SPF, DKIM, and DMARC records and updates the domain accordingly.
  """
  def verify_email_dns(%CustomDomain{email_enabled: true} = domain) do
    results =
      DNSVerification.verify_email_dns(
        domain.domain,
        domain.dkim_selector,
        domain.dkim_public_key
      )

    mx_ok = results.mx == :ok
    spf_ok = results.spf == :ok
    dkim_ok = results.dkim == :ok
    dmarc_ok = results.dmarc == :ok

    # Build error message for any failures
    errors = []
    errors = if !mx_ok, do: ["MX: #{format_dns_error(results.mx)}" | errors], else: errors
    errors = if !spf_ok, do: ["SPF: #{format_dns_error(results.spf)}" | errors], else: errors
    errors = if !dkim_ok, do: ["DKIM: #{format_dns_error(results.dkim)}" | errors], else: errors

    errors =
      if !dmarc_ok, do: ["DMARC: #{format_dns_error(results.dmarc)}" | errors], else: errors

    last_error = if Enum.empty?(errors), do: nil, else: Enum.join(errors, "; ")

    domain
    |> CustomDomain.email_dns_changeset(%{
      mx_verified: mx_ok,
      spf_verified: spf_ok,
      dkim_verified: dkim_ok,
      dmarc_verified: dmarc_ok,
      last_error: last_error
    })
    |> Repo.update()
  end

  def verify_email_dns(%CustomDomain{}) do
    {:error, :email_not_enabled}
  end

  @doc """
  Gets email configuration instructions for a custom domain.
  """
  def get_email_dns_instructions(%CustomDomain{email_enabled: true} = domain) do
    DNSVerification.email_dns_instructions(
      domain.domain,
      domain.dkim_selector,
      domain.dkim_public_key
    )
  end

  def get_email_dns_instructions(_), do: []

  @doc """
  Gets the decrypted DKIM private key for signing outgoing emails.
  """
  def get_dkim_private_key(%CustomDomain{dkim_private_key: encrypted_key})
      when is_binary(encrypted_key) do
    decrypt_system(encrypted_key)
  end

  def get_dkim_private_key(_), do: {:error, :no_dkim_key}

  @doc """
  Checks if a domain is ready for email (all required DNS records verified).
  """
  def email_ready?(%CustomDomain{} = domain) do
    CustomDomain.email_ready?(domain)
  end

  @doc """
  Sets up catch-all email for a domain.
  """
  def configure_catch_all(%CustomDomain{} = domain, mailbox_id, enabled \\ true) do
    domain
    |> CustomDomain.catch_all_changeset(%{
      catch_all_enabled: enabled,
      catch_all_mailbox_id: mailbox_id
    })
    |> Repo.update()
  end

  ## Custom Domain Addresses

  @doc """
  Adds an email address to a custom domain.

  Example: add_address(domain, "info", mailbox_id) creates info@customdomain.com
  """
  def add_address(%CustomDomain{} = domain, local_part, mailbox_id, description \\ nil) do
    %CustomDomainAddress{}
    |> CustomDomainAddress.create_changeset(%{
      custom_domain_id: domain.id,
      local_part: local_part,
      mailbox_id: mailbox_id,
      description: description
    })
    |> Repo.insert()
  end

  @doc """
  Lists all email addresses for a custom domain.
  """
  def list_addresses(%CustomDomain{} = domain) do
    CustomDomainAddress
    |> where([a], a.custom_domain_id == ^domain.id)
    |> preload(:mailbox)
    |> order_by([a], asc: a.local_part)
    |> Repo.all()
  end

  @doc """
  Gets an address by ID.
  """
  def get_address!(id) do
    CustomDomainAddress
    |> preload([:custom_domain, :mailbox])
    |> Repo.get!(id)
  end

  @doc """
  Updates an email address.
  """
  def update_address(%CustomDomainAddress{} = address, attrs) do
    address
    |> CustomDomainAddress.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an email address from a custom domain.
  """
  def delete_address(%CustomDomainAddress{} = address) do
    Repo.delete(address)
  end

  @doc """
  Finds the mailbox for an incoming email to a custom domain.

  First checks for an exact address match, then falls back to catch-all if enabled.
  Returns `{:ok, mailbox_id}` or `{:error, :not_found}`.
  """
  def find_mailbox_for_email(email) when is_binary(email) do
    case parse_email_address(email) do
      {:ok, local_part, domain} ->
        find_mailbox_for_email(local_part, domain)

      :error ->
        {:error, :invalid_email}
    end
  end

  def find_mailbox_for_email(local_part, domain) do
    domain_lower = String.downcase(domain)
    local_lower = String.downcase(local_part)

    # First, try to find exact address match
    case get_address_by_email(local_lower, domain_lower) do
      %CustomDomainAddress{enabled: true, mailbox_id: mailbox_id} ->
        {:ok, mailbox_id}

      _ ->
        # Fall back to catch-all if configured
        case get_catch_all_mailbox(domain_lower) do
          {:ok, mailbox_id} -> {:ok, mailbox_id}
          :error -> {:error, :not_found}
        end
    end
  end

  @doc """
  Gets an address by local part and domain.
  """
  def get_address_by_email(local_part, domain) do
    CustomDomainAddress
    |> join(:inner, [a], d in CustomDomain, on: a.custom_domain_id == d.id)
    |> where([a, d], d.domain == ^domain)
    |> where([a, d], a.local_part == ^local_part)
    |> preload(:mailbox)
    |> Repo.one()
  end

  @doc """
  Gets the catch-all mailbox for a domain.
  """
  def get_catch_all_mailbox(domain) do
    result =
      CustomDomain
      |> where([d], d.domain == ^domain)
      |> where([d], d.catch_all_enabled == true)
      |> where([d], not is_nil(d.catch_all_mailbox_id))
      |> select([d], d.catch_all_mailbox_id)
      |> Repo.one()

    case result do
      nil -> :error
      mailbox_id -> {:ok, mailbox_id}
    end
  end

  @doc """
  Lists all email-enabled custom domains.
  """
  def list_email_enabled_domains do
    CustomDomain
    |> where([d], d.email_enabled == true)
    |> where([d], d.status == "active")
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Lists all email-enabled custom domain names as strings.
  Used by Haraka to know which domains to accept mail for.
  """
  def list_email_enabled_domain_names do
    CustomDomain
    |> where([d], d.email_enabled == true)
    |> where([d], d.status == "active")
    |> select([d], d.domain)
    |> Repo.all()
  end

  @doc """
  Gets a custom domain by domain name for email routing.

  Only returns domains that are active and have email enabled.
  """
  def get_email_enabled_domain(domain) when is_binary(domain) do
    domain_lower = String.downcase(domain)

    CustomDomain
    |> where([d], d.domain == ^domain_lower)
    |> where([d], d.email_enabled == true)
    |> where([d], d.status == "active")
    |> preload([:user, :catch_all_mailbox])
    |> Repo.one()
  end

  @doc """
  Checks if a domain is a custom domain with email enabled.
  """
  def custom_email_domain?(domain) when is_binary(domain) do
    domain_lower = String.downcase(domain)

    CustomDomain
    |> where([d], d.domain == ^domain_lower)
    |> where([d], d.email_enabled == true)
    |> where([d], d.status == "active")
    |> Repo.exists?()
  end

  @doc """
  Gets all addresses owned by a user (across all their custom domains).
  """
  def list_user_addresses(user_id) do
    CustomDomainAddress
    |> join(:inner, [a], d in CustomDomain, on: a.custom_domain_id == d.id)
    |> where([a, d], d.user_id == ^user_id)
    |> preload([:custom_domain, :mailbox])
    |> order_by([a], asc: a.local_part)
    |> Repo.all()
  end

  ## Helpers

  defp get_server_ip do
    # Return the server's public IP for A record instructions
    # Configured via SERVER_PUBLIC_IP environment variable in runtime.exs
    Application.get_env(:elektrine, :server_public_ip) ||
      System.get_env("SERVER_PUBLIC_IP", "YOUR_SERVER_IP")
  end

  defp format_dns_error(:ok), do: "OK"
  defp format_dns_error({:error, :no_record}), do: "Record not found"
  defp format_dns_error({:error, :no_mx}), do: "MX record not found"
  defp format_dns_error({:error, :no_spf}), do: "SPF record not found"
  defp format_dns_error({:error, :no_dkim}), do: "DKIM record not found"
  defp format_dns_error({:error, :no_dmarc}), do: "DMARC record not found"
  defp format_dns_error({:error, :wrong_mx, _}), do: "MX record points to wrong server"
  defp format_dns_error({:error, :missing_include, _}), do: "SPF missing include:elektrine.com"
  defp format_dns_error({:error, :wrong_key, _}), do: "DKIM public key mismatch"
  defp format_dns_error({:error, :dns_error}), do: "DNS lookup failed"
  defp format_dns_error({:error, reason}), do: "Error: #{inspect(reason)}"
  defp format_dns_error(other), do: inspect(other)

  defp parse_email_address(email) do
    case String.split(email, "@") do
      [local, domain] when byte_size(local) > 0 and byte_size(domain) > 0 ->
        {:ok, local, domain}

      _ ->
        :error
    end
  end
end
