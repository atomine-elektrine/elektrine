defmodule Elektrine.Repo.Migrations.AddEndpointHostAndClientMtuToVpnServers do
  use Ecto.Migration

  def change do
    alter table(:vpn_servers) do
      add :endpoint_host, :string
      add :client_mtu, :integer, default: 1280
      modify :endpoint_port, :integer, null: false, default: 443
    end
  end
end
