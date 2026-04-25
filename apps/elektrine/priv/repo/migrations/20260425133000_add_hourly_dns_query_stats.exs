defmodule Elektrine.Repo.Migrations.AddHourlyDnsQueryStats do
  use Ecto.Migration

  def up do
    alter table(:dns_query_stats) do
      add :query_hour, :utc_datetime
    end

    execute("""
    UPDATE dns_query_stats
    SET query_hour = query_date::timestamp
    WHERE query_hour IS NULL
    """)

    alter table(:dns_query_stats) do
      modify :query_hour, :utc_datetime, null: false
    end

    drop_if_exists index(
                     :dns_query_stats,
                     [:zone_id, :query_date, :qname, :qtype, :rcode, :transport],
                     name: :dns_query_stats_daily_rollup_unique
                   )

    create index(:dns_query_stats, [:zone_id, :query_hour])

    create unique_index(
             :dns_query_stats,
             [:zone_id, :query_hour, :qname, :qtype, :rcode, :transport],
             name: :dns_query_stats_hourly_rollup_unique
           )
  end

  def down do
    drop_if_exists index(
                     :dns_query_stats,
                     [:zone_id, :query_hour, :qname, :qtype, :rcode, :transport],
                     name: :dns_query_stats_hourly_rollup_unique
                   )

    drop_if_exists index(:dns_query_stats, [:zone_id, :query_hour])

    create unique_index(
             :dns_query_stats,
             [:zone_id, :query_date, :qname, :qtype, :rcode, :transport],
             name: :dns_query_stats_daily_rollup_unique
           )

    alter table(:dns_query_stats) do
      remove :query_hour
    end
  end
end
