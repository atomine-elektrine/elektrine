defmodule Elektrine.Repo.Migrations.CreateEmailAliases do
  use Ecto.Migration

  def change do
    create table(:email_aliases) do
      add :alias_email, :string, null: false
      add :target_email, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :enabled, :boolean, default: true, null: false
      add :description, :string

      timestamps()
    end

    create unique_index(:email_aliases, [:alias_email])
    create index(:email_aliases, [:user_id])
    create index(:email_aliases, [:target_email])
    create index(:email_aliases, [:enabled])
  end
end
