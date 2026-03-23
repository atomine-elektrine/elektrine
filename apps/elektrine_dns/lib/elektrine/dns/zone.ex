defmodule Elektrine.DNS.Zone do
  @moduledoc """
  User-owned authoritative DNS zone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_zones" do
    field :domain, :string
    field :status, :string, default: "provisioning"
    field :kind, :string, default: "native"
    field :serial, :integer, default: 1
    field :default_ttl, :integer, default: 300
    field :soa_mname, :string
    field :soa_rname, :string
    field :soa_refresh, :integer, default: 3600
    field :soa_retry, :integer, default: 600
    field :soa_expire, :integer, default: 1_209_600
    field :soa_minimum, :integer, default: 300
    field :verified_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :last_published_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, Elektrine.Accounts.User
    has_many :records, Elektrine.DNS.Record, foreign_key: :zone_id

    timestamps(type: :utc_datetime)
  end

  def changeset(zone, attrs) do
    zone
    |> cast(attrs, [
      :domain,
      :status,
      :kind,
      :serial,
      :default_ttl,
      :soa_mname,
      :soa_rname,
      :soa_refresh,
      :soa_retry,
      :soa_expire,
      :soa_minimum,
      :verified_at,
      :last_checked_at,
      :last_published_at,
      :last_error,
      :user_id
    ])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([:domain, :status, :kind, :default_ttl, :user_id])
    |> validate_number(:default_ttl, greater_than: 0, less_than_or_equal_to: 86_400)
    |> validate_number(:soa_refresh, greater_than: 0)
    |> validate_number(:soa_retry, greater_than: 0)
    |> validate_number(:soa_expire, greater_than: 0)
    |> validate_number(:soa_minimum, greater_than: 0)
    |> validate_format(:domain, ~r/^(?:[a-z0-9-]+\.)+[a-z]{2,}$/)
    |> unique_constraint(:domain, name: :dns_zones_domain_ci_unique)
    |> foreign_key_constraint(:user_id)
  end

  def nameserver_records(%__MODULE__{domain: domain}) when is_binary(domain) do
    Elektrine.DNS.nameservers()
    |> Enum.map(fn nameserver ->
      %{type: "NS", host: domain, value: nameserver, priority: nil}
    end)
  end

  def nameserver_records(_), do: []

  def soa_record(%__MODULE__{} = zone) do
    %{
      type: "SOA",
      host: zone.domain,
      ttl: zone.default_ttl || 300,
      mname: zone.soa_mname || List.first(Elektrine.DNS.nameservers()) || "ns1.elektrine.com",
      rname: zone.soa_rname || Elektrine.DNS.soa_rname(),
      serial: zone.serial || 1,
      refresh: zone.soa_refresh || 3600,
      retry: zone.soa_retry || 600,
      expire: zone.soa_expire || 1_209_600,
      minimum: zone.soa_minimum || zone.default_ttl || 300
    }
  end

  defp normalize_domain(nil), do: nil
  defp normalize_domain(domain), do: domain |> String.trim() |> String.downcase()
end
