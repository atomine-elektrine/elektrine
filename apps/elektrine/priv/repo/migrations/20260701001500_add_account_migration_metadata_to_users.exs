defmodule Elektrine.Repo.Migrations.AddAccountMigrationMetadataToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :also_known_as, {:array, :text}, default: [], null: false
      add :moved_to, :text
    end
  end
end
