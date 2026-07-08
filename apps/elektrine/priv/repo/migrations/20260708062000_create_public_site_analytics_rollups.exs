defmodule Elektrine.Repo.Migrations.CreatePublicSiteAnalyticsRollups do
  use Ecto.Migration

  def change do
    create table(:site_analytics_daily_rollups) do
      add :host, :string, null: false
      add :date, :date, null: false
      add :views, :bigint, null: false, default: 0
      add :sessions, :bigint, null: false, default: 0
      add :bounces, :bigint, null: false, default: 0
      add :duration_seconds, :bigint, null: false, default: 0

      timestamps()
    end

    create unique_index(:site_analytics_daily_rollups, [:host, :date])
    create index(:site_analytics_daily_rollups, [:date])

    create table(:site_analytics_page_rollups) do
      add :host, :string, null: false
      add :path, :text, null: false
      add :date, :date, null: false
      add :views, :bigint, null: false, default: 0
      add :sessions, :bigint, null: false, default: 0

      timestamps()
    end

    create index(:site_analytics_page_rollups, [:host, :date])

    create table(:site_analytics_referrer_rollups) do
      add :host, :string, null: false
      add :referrer, :text, null: false
      add :date, :date, null: false
      add :sessions, :bigint, null: false, default: 0

      timestamps()
    end

    create index(:site_analytics_referrer_rollups, [:host, :date])

    create table(:site_analytics_rollup_dates, primary_key: false) do
      add :date, :date, primary_key: true
      add :refreshed_at, :utc_datetime, null: false
    end
  end
end
