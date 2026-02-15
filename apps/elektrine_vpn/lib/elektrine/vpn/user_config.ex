defmodule Elektrine.VPN.UserConfig do
  @moduledoc """
  Schema for VPN user configurations.
  Each user can have multiple configs (one per server).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "vpn_user_configs" do
    field :public_key, :string
    field :private_key, :binary
    field :allocated_ip, :string
    field :allowed_ips, :string, default: "0.0.0.0/0, ::/0"
    field :status, :string, default: "active"
    field :last_handshake_at, :utc_datetime
    field :bytes_sent, :integer, default: 0
    field :bytes_received, :integer, default: 0
    field :persistent_keepalive, :integer, default: 25
    field :metadata, :map, default: %{}

    # Bandwidth quota fields
    # 10 GB
    field :bandwidth_quota_bytes, :integer, default: 10_737_418_240
    field :quota_period_start, :utc_datetime
    field :quota_used_bytes, :integer, default: 0

    # Rate limiting
    # 50 Mbps default
    field :rate_limit_mbps, :integer, default: 50

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :vpn_server, Elektrine.VPN.Server
    has_many :connection_logs, Elektrine.VPN.ConnectionLog, foreign_key: :vpn_user_config_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user_config, attrs) do
    user_config
    |> cast(attrs, [
      :user_id,
      :vpn_server_id,
      :public_key,
      :private_key,
      :allocated_ip,
      :allowed_ips,
      :status,
      :last_handshake_at,
      :bytes_sent,
      :bytes_received,
      :persistent_keepalive,
      :metadata,
      :bandwidth_quota_bytes,
      :quota_period_start,
      :quota_used_bytes,
      :rate_limit_mbps
    ])
    |> validate_required([:user_id, :vpn_server_id, :public_key, :allocated_ip])
    |> validate_inclusion(:status, ["active", "suspended", "revoked"])
    |> validate_number(:persistent_keepalive, greater_than_or_equal_to: 0)
    |> validate_number(:bandwidth_quota_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:quota_used_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:rate_limit_mbps, greater_than: 0, less_than_or_equal_to: 1000)
    |> unique_constraint([:user_id, :vpn_server_id])
    |> unique_constraint([:vpn_server_id, :allocated_ip])
    |> unique_constraint(:public_key)
  end
end
