defmodule Elektrine.Repo.Migrations.AddSuspensionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :suspended, :boolean, default: false, null: false
      add :suspended_until, :utc_datetime
      add :suspension_reason, :text
    end

    # Add indexes for quick lookups
    create index(:users, [:suspended])
    create index(:users, [:suspended_until])
  end
end
