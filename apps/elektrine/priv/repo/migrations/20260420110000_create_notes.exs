defmodule Elektrine.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string
      add :body, :text, null: false, default: ""
      add :pinned, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:notes, [:user_id])
    create index(:notes, [:user_id, :pinned])
    create index(:notes, [:user_id, :updated_at])
  end
end
