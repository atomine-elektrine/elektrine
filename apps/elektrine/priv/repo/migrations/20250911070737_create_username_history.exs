defmodule Elektrine.Repo.Migrations.CreateUsernameHistory do
  use Ecto.Migration

  def change do
    create table(:username_history) do
      add :username, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :changed_at, :utc_datetime, null: false
      add :previous_username, :string

      timestamps(type: :utc_datetime)
    end

    # Index for checking username availability
    create index(:username_history, [:username, :changed_at])
    create index(:username_history, [:user_id, :changed_at])

    # Unique constraint to prevent duplicate entries
    create unique_index(:username_history, [:username, :user_id, :changed_at])
  end
end
