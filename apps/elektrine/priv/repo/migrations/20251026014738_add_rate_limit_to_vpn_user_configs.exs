defmodule Elektrine.Repo.Migrations.AddRateLimitToVpnUserConfigs do
  use Ecto.Migration

  def change do
    alter table(:vpn_user_configs) do
      # Rate limit in Mbps (default 50 Mbps to prevent bandwidth hogging)
      add :rate_limit_mbps, :integer, default: 50, null: false
    end
  end
end
