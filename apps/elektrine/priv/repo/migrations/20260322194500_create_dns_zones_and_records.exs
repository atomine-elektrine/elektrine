defmodule Elektrine.Repo.Migrations.CreateDnsZonesAndRecords do
  use Ecto.Migration

  def change do
    create table(:dns_zones) do
      add :domain, :string, null: false
      add :status, :string, null: false, default: "provisioning"
      add :kind, :string, null: false, default: "native"
      add :serial, :bigint, null: false, default: 1
      add :default_ttl, :integer, null: false, default: 300
      add :verification_method, :string, null: false, default: "nameserver"
      add :verification_token, :string, null: false
      add :verified_at, :utc_datetime
      add :last_checked_at, :utc_datetime
      add :last_published_at, :utc_datetime
      add :last_error, :string
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:dns_zones, [:user_id])
    create index(:dns_zones, [:status])

    create unique_index(:dns_zones, ["lower(domain)"], name: :dns_zones_domain_ci_unique)

    create table(:dns_records) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :ttl, :integer, null: false, default: 300
      add :content, :text, null: false
      add :priority, :integer
      add :weight, :integer
      add :port, :integer
      add :flags, :integer
      add :tag, :string
      add :zone_id, references(:dns_zones, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:dns_records, [:zone_id])
    create index(:dns_records, [:type])

    create unique_index(:dns_records, [:zone_id, :name, :type, :content],
             name: :dns_records_identity_unique
           )
  end
end
