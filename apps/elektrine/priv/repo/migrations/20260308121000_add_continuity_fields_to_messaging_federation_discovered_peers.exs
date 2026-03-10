defmodule Elektrine.Repo.Migrations.AddContinuityFieldsToMessagingFederationDiscoveredPeers do
  use Ecto.Migration

  def change do
    alter table(:messaging_federation_discovered_peers) do
      add_if_not_exists :trust_state, :string, default: "trusted"
      add_if_not_exists :identity_fingerprint, :string
      add_if_not_exists :previous_identity_fingerprint, :string
      add_if_not_exists :last_key_change_at, :utc_datetime
    end

    execute(
      "UPDATE messaging_federation_discovered_peers SET trust_state = 'trusted' WHERE trust_state IS NULL",
      "UPDATE messaging_federation_discovered_peers SET trust_state = NULL WHERE trust_state = 'trusted'"
    )
  end
end
