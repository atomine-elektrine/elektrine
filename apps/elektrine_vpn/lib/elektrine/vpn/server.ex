defmodule Elektrine.VPN.Server do
  @moduledoc """
  Schema for VPN servers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "vpn_servers" do
    field :name, :string
    field :location, :string
    field :country_code, :string
    field :city, :string
    field :public_ip, :string
    field :public_key, :string
    field :endpoint_port, :integer, default: 51820
    field :internal_ip_range, :string
    field :dns_servers, :string, default: "1.1.1.1, 1.0.0.1"
    field :status, :string, default: "active"
    field :max_users, :integer, default: 100
    field :current_users, :integer, default: 0
    field :minimum_trust_level, :integer, default: 0
    field :api_endpoint, :string
    field :api_key, :string
    field :metadata, :map, default: %{}

    has_many :user_configs, Elektrine.VPN.UserConfig, foreign_key: :vpn_server_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :name,
      :location,
      :country_code,
      :city,
      :public_ip,
      :public_key,
      :endpoint_port,
      :internal_ip_range,
      :dns_servers,
      :status,
      :max_users,
      :current_users,
      :api_endpoint,
      :api_key,
      :metadata,
      :minimum_trust_level
    ])
    |> validate_required([:name, :location, :public_ip, :public_key, :internal_ip_range])
    |> validate_inclusion(:status, ["active", "maintenance", "offline"])
    |> validate_number(:endpoint_port, greater_than: 0, less_than: 65536)
    |> validate_number(:max_users, greater_than: 0)
    |> validate_number(:current_users, greater_than_or_equal_to: 0)
    |> validate_number(:minimum_trust_level,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 4
    )
    |> unique_constraint(:public_ip)
  end
end
