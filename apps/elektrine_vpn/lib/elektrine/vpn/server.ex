defmodule Elektrine.VPN.Server do
  @moduledoc """
  Schema for VPN servers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "vpn_servers" do
    field :protocol, :string, default: "wireguard"
    field :name, :string
    field :location, :string
    field :country_code, :string
    field :city, :string
    field :public_ip, :string
    field :endpoint_host, :string
    field :public_key, :string
    field :endpoint_port, :integer, default: 51_820
    field :client_mtu, :integer, default: 1280
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
      :protocol,
      :location,
      :country_code,
      :city,
      :public_ip,
      :endpoint_host,
      :public_key,
      :endpoint_port,
      :client_mtu,
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
    |> validate_required([:name, :protocol, :location, :public_ip])
    |> validate_inclusion(:protocol, ["wireguard", "shadowsocks"])
    |> validate_protocol_requirements()
    |> validate_inclusion(:status, ["active", "maintenance", "offline"])
    |> validate_number(:endpoint_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:client_mtu, greater_than_or_equal_to: 576, less_than_or_equal_to: 1500)
    |> validate_number(:max_users, greater_than: 0)
    |> validate_number(:current_users, greater_than_or_equal_to: 0)
    |> validate_number(:minimum_trust_level,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 4
    )
    |> unique_constraint([:public_ip, :protocol])
  end

  defp validate_protocol_requirements(changeset) do
    case get_field(changeset, :protocol) do
      "shadowsocks" ->
        metadata = get_field(changeset, :metadata) || %{}

        start_port =
          port_value(metadata, "port_range_start") || get_field(changeset, :endpoint_port)

        end_port = port_value(metadata, "port_range_end") || start_port

        if valid_shadowsocks_cipher?(Map.get(metadata, "cipher") || Map.get(metadata, :cipher)) and
             valid_port_range?(start_port, end_port) do
          changeset
        else
          changeset
          |> maybe_add_cipher_error(metadata)
          |> maybe_add_port_range_error(start_port, end_port)
        end

      _ ->
        changeset
        |> validate_required([:public_key, :internal_ip_range])
    end
  end

  defp valid_shadowsocks_cipher?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_shadowsocks_cipher?(_value), do: false

  defp valid_port_range?(start_port, end_port)
       when is_integer(start_port) and is_integer(end_port),
       do: start_port > 0 and end_port >= start_port and end_port < 65_536

  defp valid_port_range?(_start_port, _end_port), do: false

  defp port_value(metadata, key) do
    case Map.get(metadata, key) || Map.get(metadata, String.to_atom(key)) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_add_cipher_error(changeset, metadata) do
    if valid_shadowsocks_cipher?(Map.get(metadata, "cipher") || Map.get(metadata, :cipher)) do
      changeset
    else
      add_error(changeset, :metadata, "shadowsocks servers require a cipher in metadata")
    end
  end

  defp maybe_add_port_range_error(changeset, start_port, end_port) do
    if valid_port_range?(start_port, end_port) do
      changeset
    else
      add_error(
        changeset,
        :metadata,
        "shadowsocks servers require a valid port_range_start/port_range_end"
      )
    end
  end
end
