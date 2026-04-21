defmodule Elektrine.Repo.Migrations.AddProtocolToVpnServers do
  use Ecto.Migration

  def change do
    alter table(:vpn_servers) do
      add :protocol, :string, null: false, default: "wireguard"
    end

    create index(:vpn_servers, [:protocol])
  end
end
