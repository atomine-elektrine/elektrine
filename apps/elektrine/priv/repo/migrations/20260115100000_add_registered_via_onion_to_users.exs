defmodule Elektrine.Repo.Migrations.AddRegisteredViaOnionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :registered_via_onion, :boolean, default: false, null: false
    end

    create index(:users, [:registered_via_onion])
  end
end
