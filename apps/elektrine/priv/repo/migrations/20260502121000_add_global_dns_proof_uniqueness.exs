defmodule Elektrine.Repo.Migrations.AddGlobalDnsProofUniqueness do
  use Ecto.Migration

  def change do
    create unique_index(:atomine_proofs, [:kind, :subject],
             where: "kind = 'dns' AND status IN ('pending', 'verified')",
             name: :atomine_proofs_active_dns_subject_unique
           )
  end
end
