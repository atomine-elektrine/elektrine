defmodule Elektrine.Repo.Migrations.CreateAtomineProofs do
  use Ecto.Migration

  def change do
    create table(:atomine_proofs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :claim_type, :string, null: false, default: "positive"
      add :verification_method, :string, null: false, default: "manual"
      add :subject, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :challenge, :text, null: false
      add :evidence_url, :text
      add :score_weight, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}
      add :checked_at, :utc_datetime
      add :verified_at, :utc_datetime
      add :rejected_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :reviewed_by_user_id, references(:users, on_delete: :nilify_all)
      add :review_notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:atomine_proofs, [:user_id])
    create index(:atomine_proofs, [:kind])
    create index(:atomine_proofs, [:status])
    create index(:atomine_proofs, [:reviewed_by_user_id])

    create unique_index(:atomine_proofs, [:user_id, :kind, :subject],
             where: "status IN ('pending', 'verified')",
             name: :atomine_proofs_active_subject_unique
           )
  end
end
