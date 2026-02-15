defmodule Elektrine.Repo.Migrations.GrandfatherUserHandles do
  use Ecto.Migration

  def up do
    # Assign handles to all existing users who don't have one
    execute("""
    WITH handle_assignments AS (
      SELECT
        id,
        username,
        CASE
          -- First user with this username (case-insensitive) gets the exact handle
          WHEN ROW_NUMBER() OVER (PARTITION BY LOWER(username) ORDER BY inserted_at) = 1
          THEN LOWER(username)
          -- Subsequent users get numbered variants
          ELSE LOWER(username) || ROW_NUMBER() OVER (PARTITION BY LOWER(username) ORDER BY inserted_at)
        END as new_handle
      FROM users
      WHERE handle IS NULL
    )
    UPDATE users
    SET
      handle = handle_assignments.new_handle,
      updated_at = NOW()
    FROM handle_assignments
    WHERE users.id = handle_assignments.id
    """)

    # Ensure all users have unique_id
    execute("""
    UPDATE users
    SET unique_id = 'usr_' || substr(md5(random()::text || id::text), 1, 8)
    WHERE unique_id IS NULL
    """)

    # Ensure all users have display_name (default to username)
    execute("""
    UPDATE users
    SET display_name = username
    WHERE display_name IS NULL
    """)

    # Record initial handles in handle_history
    execute("""
    INSERT INTO handle_history (user_id, handle, used_from, inserted_at, updated_at)
    SELECT
      id,
      handle,
      COALESCE(handle_changed_at, inserted_at),
      NOW(),
      NOW()
    FROM users
    WHERE handle IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM handle_history
      WHERE handle_history.user_id = users.id
      AND handle_history.handle = users.handle
    )
    """)

    # Now add the unique constraints since all users have handles
    create_if_not_exists unique_index(:users, [:handle])
    create_if_not_exists unique_index(:users, [:unique_id])
  end

  def down do
    # Remove the constraints
    drop_if_exists unique_index(:users, [:handle])
    drop_if_exists unique_index(:users, [:unique_id])

    # Note: We don't remove the handles themselves as that would be destructive
  end
end
