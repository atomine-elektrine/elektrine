defmodule Elektrine.Repo.Migrations.CreateMessagingFederationDiscoveredPeers do
  use Ecto.Migration

  def change do
    create table(:messaging_federation_discovered_peers) do
      add :domain, :string, null: false
      add :base_url, :string, null: false
      add :discovery_url, :string, null: false
      add :protocol, :string
      add :protocol_id, :string
      add :protocol_version, :string
      add :trust_state, :string, null: false, default: "trusted"
      add :identity_fingerprint, :string, null: false
      add :previous_identity_fingerprint, :string
      add :last_key_change_at, :utc_datetime
      add :identity, :map, null: false, default: %{}
      add :endpoints, :map, null: false, default: %{}
      add :features, :map, null: false, default: %{}
      add :last_discovered_at, :utc_datetime, null: false
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :messaging_federation_discovered_peers,
             [:domain],
             name: :messaging_federation_discovered_peers_domain_unique
           )
  end
end
