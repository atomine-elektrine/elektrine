defmodule Elektrine.Repo.Migrations.CreateCustomDomains do
  use Ecto.Migration

  def change do
    create table(:custom_domains) do
      add :domain, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # Verification
      add :status, :string, null: false, default: "pending_verification"
      add :verification_token, :string, null: false
      add :verified_at, :utc_datetime

      # SSL Certificate (stored encrypted)
      add :certificate, :binary
      add :private_key, :binary
      add :certificate_expires_at, :utc_datetime
      add :certificate_issued_at, :utc_datetime
      add :ssl_status, :string, null: false, default: "pending"

      # ACME HTTP-01 challenge
      add :acme_challenge_token, :string
      add :acme_challenge_response, :string

      # Error tracking
      add :last_error, :text
      add :error_count, :integer, default: 0

      timestamps()
    end

    # Domain must be unique globally
    create unique_index(:custom_domains, [:domain])

    # User lookups
    create index(:custom_domains, [:user_id])

    # Status queries (for processing pending domains)
    create index(:custom_domains, [:status])
    create index(:custom_domains, [:ssl_status])

    # Certificate renewal queries
    create index(:custom_domains, [:certificate_expires_at])

    # ACME challenge lookups (must be fast for HTTP-01 verification)
    create index(:custom_domains, [:acme_challenge_token])
  end
end
