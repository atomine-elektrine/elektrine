defmodule Elektrine.Repo.Migrations.ChangeVpnServerForeignKeyToCascade do
  use Ecto.Migration

  def up do
    # Drop the existing foreign key constraint
    execute "ALTER TABLE vpn_user_configs DROP CONSTRAINT vpn_user_configs_vpn_server_id_fkey"

    # Add new constraint with cascade delete
    alter table(:vpn_user_configs) do
      modify :vpn_server_id, references(:vpn_servers, on_delete: :delete_all), null: false
    end
  end

  def down do
    # Drop the cascade constraint
    execute "ALTER TABLE vpn_user_configs DROP CONSTRAINT vpn_user_configs_vpn_server_id_fkey"

    # Restore the original restrict constraint
    alter table(:vpn_user_configs) do
      modify :vpn_server_id, references(:vpn_servers, on_delete: :restrict), null: false
    end
  end
end
