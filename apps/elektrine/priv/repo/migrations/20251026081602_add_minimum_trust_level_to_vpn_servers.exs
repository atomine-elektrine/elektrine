defmodule Elektrine.Repo.Migrations.AddMinimumTrustLevelToVpnServers do
  use Ecto.Migration

  def change do
    alter table(:vpn_servers) do
      add :minimum_trust_level, :integer, default: 0, null: false
    end

    create index(:vpn_servers, [:minimum_trust_level])
  end
end
