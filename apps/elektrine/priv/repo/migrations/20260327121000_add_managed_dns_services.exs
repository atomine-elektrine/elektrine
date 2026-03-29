defmodule Elektrine.Repo.Migrations.AddManagedDnsServices do
  use Ecto.Migration

  def change do
    alter table(:dns_records) do
      add :source, :string, null: false, default: "user"
      add :service, :string
      add :managed, :boolean, null: false, default: false
      add :managed_key, :string
      add :required, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}
    end

    create index(:dns_records, [:zone_id, :service])

    create unique_index(:dns_records, [:zone_id, :managed_key],
             where: "managed_key IS NOT NULL",
             name: :dns_records_zone_managed_key_unique
           )

    create table(:dns_zone_service_configs) do
      add :service, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :mode, :string, null: false, default: "managed"
      add :status, :string, null: false, default: "pending"
      add :settings, :map, null: false, default: %{}
      add :last_applied_at, :utc_datetime
      add :last_error, :string
      add :zone_id, references(:dns_zones, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:dns_zone_service_configs, [:zone_id])

    create unique_index(:dns_zone_service_configs, [:zone_id, :service],
             name: :dns_zone_service_configs_zone_service_unique
           )
  end
end
