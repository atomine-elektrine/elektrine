defmodule Elektrine.Repo.Migrations.AllowMultipleVpnProtocolsPerPublicIp do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:vpn_servers, [:public_ip])
    create unique_index(:vpn_servers, [:public_ip, :protocol])
  end
end
