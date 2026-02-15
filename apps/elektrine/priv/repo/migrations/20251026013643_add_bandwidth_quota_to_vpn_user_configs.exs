defmodule Elektrine.Repo.Migrations.AddBandwidthQuotaToVpnUserConfigs do
  use Ecto.Migration

  def change do
    alter table(:vpn_user_configs) do
      # Bandwidth quota in bytes (default 10GB = 10737418240 bytes)
      add :bandwidth_quota_bytes, :bigint, default: 10_737_418_240, null: false

      # When the quota period started (for monthly resets)
      add :quota_period_start, :utc_datetime

      # Total bandwidth used in current period (bytes_sent + bytes_received since last reset)
      add :quota_used_bytes, :bigint, default: 0, null: false
    end
  end
end
