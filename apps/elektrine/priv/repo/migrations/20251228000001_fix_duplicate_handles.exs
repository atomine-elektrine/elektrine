defmodule Elektrine.Repo.Migrations.FixDuplicateHandles do
  use Ecto.Migration

  def up do
    # First, identify and fix duplicate handles
    execute """
    WITH duplicates AS (
      SELECT handle, COUNT(*) as count
      FROM users
      WHERE handle IS NOT NULL
      GROUP BY handle
      HAVING COUNT(*) > 1
    ),
    ranked_duplicates AS (
      SELECT u.id, u.handle, u.inserted_at,
             ROW_NUMBER() OVER (PARTITION BY u.handle ORDER BY u.inserted_at ASC) as rn
      FROM users u
      INNER JOIN duplicates d ON u.handle = d.handle
    )
    UPDATE users
    SET handle = CONCAT(handle, '_', id)
    WHERE id IN (
      SELECT id FROM ranked_duplicates WHERE rn > 1
    );
    """

    # Now ensure the unique index exists
    # Drop if exists first to avoid errors
    drop_if_exists index(:users, [:handle])

    # Create unique index
    create unique_index(:users, [:handle])
  end

  def down do
    # Remove the unique index
    drop_if_exists index(:users, [:handle])
  end
end
