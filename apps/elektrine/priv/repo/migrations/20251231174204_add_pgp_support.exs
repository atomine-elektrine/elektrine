defmodule Elektrine.Repo.Migrations.AddPgpSupport do
  use Ecto.Migration

  def change do
    # Add PGP public key to users table (user's own key for others to encrypt to them)
    alter table(:users) do
      add :pgp_public_key, :text
      # Short key ID (last 8 hex chars of fingerprint)
      add :pgp_key_id, :string
      # Full 40-char fingerprint
      add :pgp_fingerprint, :string
      add :pgp_key_uploaded_at, :utc_datetime
    end

    # Add PGP public key to contacts (for encrypting outgoing mail to them)
    alter table(:contacts) do
      add :pgp_public_key, :text
      add :pgp_key_id, :string
      add :pgp_fingerprint, :string
      # "manual", "wkd", "keyserver"
      add :pgp_key_source, :string
      add :pgp_key_fetched_at, :utc_datetime
      add :pgp_encrypt_by_default, :boolean, default: false
    end

    # Create index for looking up contacts by fingerprint
    create index(:contacts, [:pgp_fingerprint])
    create index(:users, [:pgp_fingerprint])

    # Cache table for WKD lookups (to avoid repeated network requests)
    create table(:pgp_key_cache) do
      add :email, :string, null: false
      # null if no key found
      add :public_key, :text
      add :key_id, :string
      add :fingerprint, :string
      # "wkd", "keyserver", "dns"
      add :source, :string
      # "found", "not_found", "error"
      add :status, :string, default: "found"
      add :expires_at, :utc_datetime

      timestamps()
    end

    create unique_index(:pgp_key_cache, [:email])
    create index(:pgp_key_cache, [:expires_at])
  end
end
