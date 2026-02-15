defmodule Elektrine.Repo.Migrations.CreatePlatformUpdates do
  use Ecto.Migration

  def change do
    create table(:platform_updates) do
      add :title, :string, null: false
      add :description, :text
      add :badge, :string
      add :items, {:array, :string}, default: []
      add :published, :boolean, default: true
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps()
    end

    create index(:platform_updates, [:created_by_id])
    create index(:platform_updates, [:published, :inserted_at])
  end
end
