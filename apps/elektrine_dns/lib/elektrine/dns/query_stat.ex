defmodule Elektrine.DNS.QueryStat do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_query_stats" do
    field :query_date, :date
    field :query_hour, :utc_datetime
    field :qname, :string
    field :qtype, :string
    field :rcode, :string
    field :transport, :string
    field :query_count, :integer, default: 0

    belongs_to :zone, Elektrine.DNS.Zone

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(query_stat, attrs) do
    query_stat
    |> cast(attrs, [
      :query_date,
      :query_hour,
      :qname,
      :qtype,
      :rcode,
      :transport,
      :query_count,
      :zone_id
    ])
    |> validate_required([
      :query_date,
      :query_hour,
      :qname,
      :qtype,
      :rcode,
      :transport,
      :query_count,
      :zone_id
    ])
    |> validate_number(:query_count, greater_than: 0)
    |> foreign_key_constraint(:zone_id)
  end
end
