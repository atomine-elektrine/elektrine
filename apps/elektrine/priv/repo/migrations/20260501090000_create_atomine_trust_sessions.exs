defmodule Elektrine.Repo.Migrations.CreateAtomineTrustSessions do
  use Ecto.Migration

  def change do
    create table(:atomine_trust_sessions) do
      add :public_id, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :context, :string, null: false
      add :merchant_id, :string
      add :external_subject, :string
      add :status, :string, null: false, default: "pending"
      add :decision, :string, null: false, default: "review"
      add :recommended_step_up, :string
      add :score, :integer, null: false, default: 0
      add :level, :string, null: false, default: "unknown"
      add :signals, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :expires_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:atomine_trust_sessions, [:public_id])
    create index(:atomine_trust_sessions, [:user_id])
    create index(:atomine_trust_sessions, [:context])
    create index(:atomine_trust_sessions, [:merchant_id])
    create index(:atomine_trust_sessions, [:status])
    create index(:atomine_trust_sessions, [:decision])
  end
end
