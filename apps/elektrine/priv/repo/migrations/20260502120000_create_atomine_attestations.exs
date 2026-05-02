defmodule Elektrine.Repo.Migrations.CreateAtomineAttestations do
  use Ecto.Migration

  def change do
    create table(:atomine_attestations) do
      add :public_id, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :passkey_credential_id, references(:passkey_credentials, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :status, :string, null: false, default: "issued"
      add :issuer, :string, null: false
      add :subject, :text
      add :subject_hash, :string
      add :artifact_hash, :string, null: false
      add :artifact, :text, null: false
      add :difficulty, :integer
      add :metadata, :map, null: false, default: %{}
      add :issued_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      add :redeemed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:atomine_attestations, [:public_id])
    create unique_index(:atomine_attestations, [:artifact_hash])
    create index(:atomine_attestations, [:user_id])
    create index(:atomine_attestations, [:passkey_credential_id])
    create index(:atomine_attestations, [:kind])
    create index(:atomine_attestations, [:status])
    create index(:atomine_attestations, [:subject_hash])
    create index(:atomine_attestations, [:expires_at])
  end
end
