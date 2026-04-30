defmodule Elektrine.Repo.Migrations.AddClaimFieldsToAtomineProofs do
  use Ecto.Migration

  def change do
    alter table(:atomine_proofs) do
      add_if_not_exists :claim_type, :string, null: false, default: "positive"
      add_if_not_exists :verification_method, :string, null: false, default: "manual"
      add_if_not_exists :checked_at, :utc_datetime
    end
  end
end
