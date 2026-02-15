defmodule Elektrine.CustomDomains.CustomDomain do
  @moduledoc """
  Schema for custom domains that users can point to their profiles and use for email.

  ## Status Flow

      pending_verification → verified → provisioning_ssl → active
                          ↘ verification_failed
                                                       ↘ ssl_failed

  ## SSL Status

  - pending: No certificate yet
  - provisioning: ACME challenge in progress
  - issued: Certificate successfully obtained
  - failed: Certificate provisioning failed
  - expired: Certificate has expired (needs renewal)

  ## Email Support

  Custom domains can optionally be enabled for email. When email is enabled:
  - User must configure MX records pointing to our mail servers
  - User must configure SPF, DKIM, and DMARC records
  - Outgoing emails are signed with domain-specific DKIM keys
  - Incoming emails are routed based on custom_domain_addresses configuration
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending_verification verified verification_failed provisioning_ssl active ssl_failed suspended)
  @ssl_statuses ~w(pending provisioning issued failed expired)

  schema "custom_domains" do
    field :domain, :string
    field :status, :string, default: "pending_verification"
    field :verification_token, :string
    field :verified_at, :utc_datetime

    # SSL Certificate (encrypted at rest)
    field :certificate, :binary
    field :private_key, :binary
    field :certificate_expires_at, :utc_datetime
    field :certificate_issued_at, :utc_datetime
    field :ssl_status, :string, default: "pending"

    # ACME HTTP-01 challenge
    field :acme_challenge_token, :string
    field :acme_challenge_response, :string

    # Error tracking
    field :last_error, :string
    field :error_count, :integer, default: 0

    # Email support
    field :email_enabled, :boolean, default: false
    field :mx_verified, :boolean, default: false
    field :spf_verified, :boolean, default: false
    field :dkim_verified, :boolean, default: false
    field :dmarc_verified, :boolean, default: false
    field :email_dns_verified_at, :utc_datetime

    # DKIM key pair (encrypted at rest)
    field :dkim_private_key, :binary
    field :dkim_public_key, :string
    field :dkim_selector, :string, default: "elektrine"

    # Catch-all configuration
    field :catch_all_enabled, :boolean, default: false

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :catch_all_mailbox, {"mailboxes", Elektrine.Email.Mailbox}

    has_many :addresses, Elektrine.CustomDomains.CustomDomainAddress

    timestamps()
  end

  @doc """
  Changeset for creating a new custom domain.
  """
  def create_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [:domain, :user_id])
    |> validate_required([:domain, :user_id])
    |> validate_domain()
    |> generate_verification_token()
    |> unique_constraint(:domain, message: "is already registered")
  end

  @doc """
  Changeset for updating domain status after verification.
  """
  def verification_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [:status, :verified_at, :last_error, :error_count])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset for storing ACME challenge data.
  """
  def acme_challenge_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [:acme_challenge_token, :acme_challenge_response, :status, :ssl_status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:ssl_status, @ssl_statuses)
  end

  @doc """
  Changeset for storing SSL certificate after successful provisioning.
  """
  def certificate_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [
      :certificate,
      :private_key,
      :certificate_expires_at,
      :certificate_issued_at,
      :ssl_status,
      :status,
      :last_error,
      :error_count
    ])
    |> validate_inclusion(:ssl_status, @ssl_statuses)
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset for marking SSL provisioning as failed.
  """
  def ssl_error_changeset(custom_domain, error) do
    custom_domain
    |> change(%{
      ssl_status: "failed",
      status: "ssl_failed",
      last_error: error,
      error_count: (custom_domain.error_count || 0) + 1
    })
  end

  @doc """
  Changeset for suspending a domain.
  """
  def suspend_changeset(custom_domain, reason) do
    custom_domain
    |> change(%{
      status: "suspended",
      last_error: reason
    })
  end

  @doc """
  Changeset for enabling email on a custom domain.
  This generates DKIM keys and sets up the domain for email.
  """
  def enable_email_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [:email_enabled, :dkim_private_key, :dkim_public_key, :dkim_selector])
    |> validate_required_if_email_enabled()
  end

  @doc """
  Changeset for updating email DNS verification status.
  """
  def email_dns_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [
      :mx_verified,
      :spf_verified,
      :dkim_verified,
      :dmarc_verified,
      :email_dns_verified_at,
      :last_error
    ])
    |> maybe_set_dns_verified_at()
  end

  @doc """
  Changeset for configuring catch-all email for the domain.
  """
  def catch_all_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [:catch_all_enabled, :catch_all_mailbox_id])
    |> validate_catch_all_mailbox()
  end

  @doc """
  Changeset for storing DKIM keys.
  """
  def dkim_changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [:dkim_private_key, :dkim_public_key, :dkim_selector])
    |> validate_required([:dkim_private_key, :dkim_public_key, :dkim_selector])
  end

  @doc """
  Returns true if the domain is fully configured for email.
  """
  def email_ready?(%__MODULE__{} = domain) do
    domain.email_enabled &&
      domain.status == "active" &&
      domain.mx_verified &&
      domain.spf_verified &&
      domain.dkim_verified &&
      domain.dkim_private_key != nil
  end

  @doc """
  Returns a list of missing DNS records for email configuration.
  """
  def missing_email_dns_records(%__MODULE__{} = domain) do
    []
    |> maybe_add_missing(:mx, !domain.mx_verified)
    |> maybe_add_missing(:spf, !domain.spf_verified)
    |> maybe_add_missing(:dkim, !domain.dkim_verified)
    |> maybe_add_missing(:dmarc, !domain.dmarc_verified)
  end

  defp maybe_add_missing(list, record, true), do: [record | list]
  defp maybe_add_missing(list, _record, false), do: list

  # Private functions

  defp validate_required_if_email_enabled(changeset) do
    if get_field(changeset, :email_enabled) do
      changeset
      |> validate_required([:dkim_private_key, :dkim_public_key])
    else
      changeset
    end
  end

  defp maybe_set_dns_verified_at(changeset) do
    mx = get_field(changeset, :mx_verified)
    spf = get_field(changeset, :spf_verified)
    dkim = get_field(changeset, :dkim_verified)

    if mx && spf && dkim && is_nil(get_field(changeset, :email_dns_verified_at)) do
      put_change(
        changeset,
        :email_dns_verified_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      changeset
    end
  end

  defp validate_catch_all_mailbox(changeset) do
    catch_all_enabled = get_field(changeset, :catch_all_enabled)
    catch_all_mailbox_id = get_field(changeset, :catch_all_mailbox_id)

    if catch_all_enabled && is_nil(catch_all_mailbox_id) do
      add_error(changeset, :catch_all_mailbox_id, "is required when catch-all is enabled")
    else
      changeset
    end
  end

  # Private functions

  defp validate_domain(changeset) do
    changeset
    |> validate_length(:domain, min: 4, max: 253)
    |> validate_format(
      :domain,
      ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i,
      message: "must be a valid domain name"
    )
    |> validate_not_reserved_domain()
    |> update_change(:domain, &String.downcase/1)
  end

  defp validate_not_reserved_domain(changeset) do
    domain = get_change(changeset, :domain)

    if domain do
      domain_lower = String.downcase(domain)

      reserved_patterns = [
        # Our domains
        ~r/\.?elektrine\.com$/,
        ~r/\.?z\.org$/,
        # Common TLDs that shouldn't be custom domains
        ~r/\.?localhost$/,
        ~r/\.?local$/,
        ~r/\.?test$/,
        ~r/\.?example\.(com|org|net)$/,
        # Fly.io
        ~r/\.?fly\.dev$/,
        ~r/\.?fly\.io$/,
        # Other platforms
        ~r/\.?herokuapp\.com$/,
        ~r/\.?vercel\.app$/,
        ~r/\.?netlify\.app$/,
        ~r/\.?pages\.dev$/,
        ~r/\.?workers\.dev$/
      ]

      if Enum.any?(reserved_patterns, &Regex.match?(&1, domain_lower)) do
        add_error(changeset, :domain, "is a reserved domain and cannot be used")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp generate_verification_token(changeset) do
    if get_change(changeset, :domain) do
      token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      put_change(changeset, :verification_token, token)
    else
      changeset
    end
  end
end
