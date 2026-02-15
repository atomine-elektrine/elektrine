defmodule Elektrine.Repo.Migrations.CreateUserBlocks do
  use Ecto.Migration

  def change do
    create table(:user_blocks) do
      add :blocker_id, references(:users, on_delete: :delete_all), null: false
      add :blocked_id, references(:users, on_delete: :delete_all), null: false
      add :reason, :string

      timestamps()
    end

    create unique_index(:user_blocks, [:blocker_id, :blocked_id])
    create index(:user_blocks, [:blocker_id])
    create index(:user_blocks, [:blocked_id])
  end
end
