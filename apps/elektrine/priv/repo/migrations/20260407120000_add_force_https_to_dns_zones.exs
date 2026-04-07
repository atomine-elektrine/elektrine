defmodule Elektrine.Repo.Migrations.AddForceHttpsToDnsZones do
  use Ecto.Migration

  def change do
    alter table(:dns_zones) do
      add :force_https, :boolean, null: false, default: false
    end
  end
end
