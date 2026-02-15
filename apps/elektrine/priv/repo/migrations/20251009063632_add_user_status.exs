defmodule Elektrine.Repo.Migrations.AddUserStatus do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :status, :string, default: "online", null: false
      add :status_message, :string
      add :status_updated_at, :utc_datetime
    end

    create index(:users, [:status])
  end
end
