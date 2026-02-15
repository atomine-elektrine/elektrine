defmodule Elektrine.Repo.Migrations.AddEmailSupportToCustomDomains do
  use Ecto.Migration

  def change do
    # Add email-related fields to custom_domains table
    alter table(:custom_domains) do
      # Email feature toggle
      add :email_enabled, :boolean, default: false, null: false

      # Email DNS verification status
      add :mx_verified, :boolean, default: false, null: false
      add :spf_verified, :boolean, default: false, null: false
      add :dkim_verified, :boolean, default: false, null: false
      add :dmarc_verified, :boolean, default: false, null: false
      add :email_dns_verified_at, :utc_datetime

      # DKIM key pair for signing outgoing emails (encrypted at rest)
      add :dkim_private_key, :binary
      add :dkim_public_key, :text
      add :dkim_selector, :string, default: "elektrine"

      # Email configuration
      add :catch_all_enabled, :boolean, default: false, null: false
      add :catch_all_mailbox_id, references(:mailboxes, on_delete: :nilify_all)
    end

    # Create table for custom domain email addresses
    create table(:custom_domain_addresses) do
      add :custom_domain_id, references(:custom_domains, on_delete: :delete_all), null: false
      add :local_part, :string, null: false
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :enabled, :boolean, default: true, null: false
      add :description, :string

      timestamps()
    end

    # Each local part must be unique per domain
    create unique_index(:custom_domain_addresses, [:custom_domain_id, :local_part])

    # Fast lookup by mailbox (show all custom domain addresses for a user's mailbox)
    create index(:custom_domain_addresses, [:mailbox_id])

    # Email-enabled domain queries
    create index(:custom_domains, [:email_enabled])
  end
end
