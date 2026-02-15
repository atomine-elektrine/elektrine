defmodule Elektrine.Repo.Migrations.CreateAnnouncementDismissals do
  use Ecto.Migration

  def change do
    create table(:announcement_dismissals) do
      add :dismissed_at, :utc_datetime, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :announcement_id, references(:announcements, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:announcement_dismissals, [:user_id])
    create index(:announcement_dismissals, [:announcement_id])
    create unique_index(:announcement_dismissals, [:user_id, :announcement_id])
  end
end
