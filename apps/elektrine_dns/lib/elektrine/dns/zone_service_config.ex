defmodule Elektrine.DNS.ZoneServiceConfig do
  @moduledoc """
  Per-zone managed DNS service configuration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @services ~w(mail web dns vpn bluesky)
  @modes ~w(managed manual)
  @statuses ~w(pending ok conflict disabled error)

  schema "dns_zone_service_configs" do
    field :service, :string
    field :enabled, :boolean, default: true
    field :mode, :string, default: "managed"
    field :status, :string, default: "pending"
    field :settings, :map, default: %{}
    field :last_applied_at, :utc_datetime
    field :last_error, :string

    belongs_to :zone, Elektrine.DNS.Zone

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :service,
      :enabled,
      :mode,
      :status,
      :settings,
      :last_applied_at,
      :last_error,
      :zone_id
    ])
    |> update_change(:service, &normalize_service/1)
    |> update_change(:mode, &normalize_mode/1)
    |> update_change(:status, &normalize_status/1)
    |> validate_required([:service, :enabled, :mode, :status, :zone_id])
    |> validate_inclusion(:service, @services)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:zone_id)
    |> unique_constraint(:service, name: :dns_zone_service_configs_zone_service_unique)
  end

  def services, do: @services

  defp normalize_service(nil), do: nil
  defp normalize_service(value), do: value |> String.trim() |> String.downcase()

  defp normalize_mode(nil), do: nil
  defp normalize_mode(value), do: value |> String.trim() |> String.downcase()

  defp normalize_status(nil), do: nil
  defp normalize_status(value), do: value |> String.trim() |> String.downcase()
end
