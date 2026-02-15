defmodule Elektrine.Repo.Migrations.AddCaseInsensitiveHandleIndex do
  use Ecto.Migration

  def change do
    # Drop the old case-sensitive unique index on handle
    drop_if_exists index(:users, [:handle], unique: true)

    # Create case-insensitive unique index on handle
    create unique_index(:users, ["lower(handle)"], name: :users_handle_ci_unique)
  end
end
