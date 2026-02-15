defmodule Elektrine.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  def change do
    create table(:announcements) do
      add :title, :string, null: false
      add :content, :text, null: false
      add :type, :string, null: false, default: "info"
      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
      add :active, :boolean, default: true, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:announcements, [:created_by_id])
    create index(:announcements, [:active])
    create index(:announcements, [:starts_at])
    create index(:announcements, [:ends_at])
    create index(:announcements, [:type])
  end
end
