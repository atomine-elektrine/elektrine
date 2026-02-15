defmodule Elektrine.Repo.Migrations.AddEmailProtocolTracking do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_imap_access, :utc_datetime
      add :last_pop3_access, :utc_datetime
    end

    # Create indexes for efficient querying
    create index(:users, [:last_imap_access])
    create index(:users, [:last_pop3_access])
  end
end
