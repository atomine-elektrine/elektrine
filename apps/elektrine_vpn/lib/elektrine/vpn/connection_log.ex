defmodule Elektrine.VPN.ConnectionLog do
  @moduledoc """
  Schema for VPN connection logs.
  Tracks connection history and data usage.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "vpn_connection_logs" do
    field :connected_at, :utc_datetime
    field :disconnected_at, :utc_datetime
    field :bytes_sent, :integer, default: 0
    field :bytes_received, :integer, default: 0
    field :client_ip, :string
    field :metadata, :map, default: %{}

    belongs_to :vpn_user_config, Elektrine.VPN.UserConfig

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(connection_log, attrs) do
    connection_log
    |> cast(attrs, [
      :vpn_user_config_id,
      :connected_at,
      :disconnected_at,
      :bytes_sent,
      :bytes_received,
      :client_ip,
      :metadata
    ])
    |> validate_required([:vpn_user_config_id, :connected_at])
  end
end
