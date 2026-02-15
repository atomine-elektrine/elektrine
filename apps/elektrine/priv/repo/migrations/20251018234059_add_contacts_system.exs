defmodule Elektrine.Repo.Migrations.AddContactsSystem do
  use Ecto.Migration

  def change do
    # Contact groups/categories
    create table(:contact_groups) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string, default: "#3b82f6"

      timestamps()
    end

    create index(:contact_groups, [:user_id])

    # Contacts
    create table(:contacts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string
      add :organization, :string
      add :notes, :text
      add :favorite, :boolean, default: false
      add :group_id, references(:contact_groups, on_delete: :nilify_all)

      timestamps()
    end

    create index(:contacts, [:user_id])
    create index(:contacts, [:user_id, :favorite])
    create index(:contacts, [:group_id])
    create unique_index(:contacts, [:user_id, :email])
  end
end
