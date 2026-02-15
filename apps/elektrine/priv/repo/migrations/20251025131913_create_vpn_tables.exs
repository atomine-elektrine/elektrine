defmodule Elektrine.Repo.Migrations.CreateVpnTables do
  use Ecto.Migration

  def change do
    # VPN Servers table
    create table(:vpn_servers) do
      add :name, :string, null: false
      # e.g., "US - New York"
      add :location, :string, null: false
      # e.g., "US"
      add :country_code, :string, size: 2
      add :city, :string
      add :public_ip, :string, null: false
      add :public_key, :string, null: false
      add :endpoint_port, :integer, null: false, default: 51820
      # e.g., "10.8.0.0/24"
      add :internal_ip_range, :string, null: false
      add :dns_servers, :string, default: "1.1.1.1, 1.0.0.1"
      # active, maintenance, offline
      add :status, :string, null: false, default: "active"
      add :max_users, :integer, default: 100
      add :current_users, :integer, default: 0
      # URL for server management API
      add :api_endpoint, :string
      # Encrypted API key for authentication
      add :api_key, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vpn_servers, [:public_ip])
    create index(:vpn_servers, [:status])
    create index(:vpn_servers, [:country_code])

    # VPN User Configurations table
    create table(:vpn_user_configs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :vpn_server_id, references(:vpn_servers, on_delete: :restrict), null: false
      add :public_key, :string, null: false
      # Encrypted WireGuard private key
      add :private_key, :binary
      # e.g., "10.8.0.2/32"
      add :allocated_ip, :string, null: false
      # Full tunnel by default
      add :allowed_ips, :string, default: "0.0.0.0/0, ::/0"
      # active, suspended, revoked
      add :status, :string, null: false, default: "active"
      add :last_handshake_at, :utc_datetime
      add :bytes_sent, :bigint, default: 0
      add :bytes_received, :bigint, default: 0
      add :persistent_keepalive, :integer, default: 25
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vpn_user_configs, [:user_id, :vpn_server_id])
    create unique_index(:vpn_user_configs, [:vpn_server_id, :allocated_ip])
    create unique_index(:vpn_user_configs, [:public_key])
    create index(:vpn_user_configs, [:user_id])
    create index(:vpn_user_configs, [:vpn_server_id])
    create index(:vpn_user_configs, [:status])

    # VPN Connection Logs table (for analytics and monitoring)
    create table(:vpn_connection_logs) do
      add :vpn_user_config_id, references(:vpn_user_configs, on_delete: :delete_all), null: false
      add :connected_at, :utc_datetime, null: false
      add :disconnected_at, :utc_datetime
      add :bytes_sent, :bigint, default: 0
      add :bytes_received, :bigint, default: 0
      # The actual IP the client connected from
      add :client_ip, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:vpn_connection_logs, [:vpn_user_config_id])
    create index(:vpn_connection_logs, [:connected_at])
  end
end
