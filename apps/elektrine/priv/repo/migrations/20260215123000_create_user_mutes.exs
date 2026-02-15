defmodule Elektrine.Repo.Migrations.CreateUserMutes do
  use Ecto.Migration

  def change do
    create table(:user_mutes) do
      add :muter_id, references(:users, on_delete: :delete_all), null: false
      add :muted_id, references(:users, on_delete: :delete_all), null: false
      add :mute_notifications, :boolean, default: false, null: false

      timestamps()
    end

    create index(:user_mutes, [:muter_id])
    create index(:user_mutes, [:muted_id])
    create unique_index(:user_mutes, [:muter_id, :muted_id])
  end
end
