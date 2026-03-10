defmodule Elektrine.Email.CustomDomain do
  @moduledoc """
  Schema for user-managed custom email domains.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Inspect, except: [:dkim_private_key]}
  @statuses ~w(pending verified)
  @domain_regex ~r/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  schema "email_custom_domains" do
    field :domain, :string
    field :verification_token, :string
    field :dkim_selector, :string
    field :dkim_public_key, :string
    field :dkim_private_key, :string, redact: true
    field :dkim_synced_at, :utc_datetime
    field :dkim_last_error, :string
    field :status, :string, default: "pending"
    field :verified_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(custom_domain, attrs) do
    custom_domain
    |> cast(attrs, [
      :domain,
      :verification_token,
      :dkim_selector,
      :dkim_public_key,
      :dkim_private_key,
      :dkim_synced_at,
      :dkim_last_error,
      :status,
      :verified_at,
      :last_checked_at,
      :last_error,
      :user_id
    ])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([
      :domain,
      :verification_token,
      :status,
      :user_id
    ])
    |> validate_length(:domain, max: 253)
    |> validate_length(:verification_token, max: 255)
    |> validate_length(:dkim_selector, max: 255)
    |> validate_length(:last_error, max: 255)
    |> validate_length(:dkim_last_error, max: 255)
    |> validate_format(:domain, @domain_regex, message: "must be a valid domain name")
    |> validate_exclusion(:domain, Elektrine.Domains.supported_email_domains(),
      message: "is already managed by the system"
    )
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:domain,
      name: :email_custom_domains_domain_ci_unique,
      message: "is already claimed"
    )
    |> foreign_key_constraint(:user_id)
  end

  defp normalize_domain(nil), do: nil

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_domain(domain), do: domain
end
