defmodule Elektrine.Repo.Migrations.AddDnsZoneSoaFields do
  use Ecto.Migration

  def change do
    alter table(:dns_zones) do
      add :soa_mname, :string
      add :soa_rname, :string
      add :soa_refresh, :integer, null: false, default: 3600
      add :soa_retry, :integer, null: false, default: 600
      add :soa_expire, :integer, null: false, default: 1_209_600
      add :soa_minimum, :integer, null: false, default: 300
    end
  end
end
