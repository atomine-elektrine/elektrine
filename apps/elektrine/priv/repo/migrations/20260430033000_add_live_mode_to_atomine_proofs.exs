defmodule Elektrine.Repo.Migrations.AddLiveModeToAtomineProofs do
  use Ecto.Migration

  def change do
    alter table(:atomine_proofs) do
      add_if_not_exists :proof_mode, :string, null: false, default: "snapshot"
      add_if_not_exists :live_status, :string
      add_if_not_exists :last_seen_at, :utc_datetime
      add_if_not_exists :next_check_at, :utc_datetime
      add_if_not_exists :stale_at, :utc_datetime
      add_if_not_exists :failed_check_count, :integer, null: false, default: 0
    end

    create index(:atomine_proofs, [:proof_mode])
    create index(:atomine_proofs, [:live_status])
    create index(:atomine_proofs, [:next_check_at])
  end
end
