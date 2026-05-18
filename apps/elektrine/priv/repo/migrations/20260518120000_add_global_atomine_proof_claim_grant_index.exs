defmodule Elektrine.Repo.Migrations.AddGlobalAtomineProofClaimGrantIndex do
  use Ecto.Migration

  def change do
    create unique_index(
             :atomine_credit_ledger_entries,
             [:credit_type, :reference_type, :reference_id],
             name: :atomine_credit_ledger_entries_global_proof_claim_index,
             where:
               "amount > 0 AND credit_type = 'atomine_credit' AND reference_type = 'atomine_proof_claim'"
           )
  end
end
