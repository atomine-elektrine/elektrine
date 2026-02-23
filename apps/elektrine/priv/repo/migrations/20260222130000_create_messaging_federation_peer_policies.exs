defmodule Elektrine.Repo.Migrations.CreateMessagingFederationPeerPolicies do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_peer_policies) do
      add :domain, :string, null: false
      add :allow_incoming, :boolean
      add :allow_outgoing, :boolean
      add :blocked, :boolean, null: false, default: false
      add :reason, :text
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:messaging_federation_peer_policies, [:domain],
             name: :messaging_federation_peer_policies_domain_unique
           )

    create index(:messaging_federation_peer_policies, [:blocked])
    create index(:messaging_federation_peer_policies, [:updated_by_id])
  end
end
