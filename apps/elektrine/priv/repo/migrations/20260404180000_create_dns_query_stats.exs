defmodule Elektrine.Repo.Migrations.CreateDnsQueryStats do
  use Ecto.Migration

  def change do
    create table(:dns_query_stats) do
      add :query_date, :date, null: false
      add :qname, :string, null: false
      add :qtype, :string, null: false
      add :rcode, :string, null: false
      add :transport, :string, null: false
      add :query_count, :integer, null: false, default: 0
      add :zone_id, references(:dns_zones, on_delete: :delete_all), null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:dns_query_stats, [:zone_id])
    create index(:dns_query_stats, [:zone_id, :query_date])

    create unique_index(
             :dns_query_stats,
             [:zone_id, :query_date, :qname, :qtype, :rcode, :transport],
             name: :dns_query_stats_daily_rollup_unique
           )
  end
end
