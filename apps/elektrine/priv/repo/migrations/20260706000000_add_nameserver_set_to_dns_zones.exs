defmodule Elektrine.Repo.Migrations.AddNameserverSetToDnsZones do
  use Ecto.Migration

  def change do
    alter table(:dns_zones) do
      add :nameserver_set, :integer
    end
  end
end
