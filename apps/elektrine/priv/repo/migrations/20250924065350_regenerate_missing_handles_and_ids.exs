defmodule Elektrine.Repo.Migrations.RegenerateMissingHandlesAndIds do
  use Ecto.Migration

  def up do
    # Regenerate unique IDs for users who don't have one
    execute("""
    UPDATE users
    SET
      unique_id = 'usr_' || substr(md5(random()::text || id::text), 1, 8),
      updated_at = NOW()
    WHERE unique_id IS NULL OR unique_id = ''
    """)

    # Regenerate handles for users who don't have one
    # Use a more complex approach to ensure uniqueness
    execute("""
    WITH handle_assignments AS (
      SELECT
        id,
        username,
        CASE
          -- First try the lowercase username
          WHEN NOT EXISTS (
            SELECT 1 FROM users u2
            WHERE u2.handle = LOWER(users.username)
            AND u2.id != users.id
          )
          THEN LOWER(username)
          -- Otherwise, add numbers until we find an available one
          ELSE (
            SELECT LOWER(username) || COALESCE(
              (SELECT MIN(n::text)
               FROM generate_series(1, 10000) n
               WHERE NOT EXISTS (
                 SELECT 1 FROM users u3
                 WHERE u3.handle = LOWER(users.username) || n::text
               )),
              '10001'
            )
          )
        END as new_handle
      FROM users
      WHERE handle IS NULL OR handle = ''
    )
    UPDATE users
    SET
      handle = handle_assignments.new_handle,
      updated_at = NOW()
    FROM handle_assignments
    WHERE users.id = handle_assignments.id
    """)

    # Ensure all users have display_name (default to username)
    execute("""
    UPDATE users
    SET
      display_name = username,
      updated_at = NOW()
    WHERE display_name IS NULL OR display_name = ''
    """)

    # Record any newly assigned handles in handle_history
    # Skip if the record already exists
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

    # Log summary of changes
    execute("""
    DO $$
    DECLARE
      updated_unique_ids INT;
      updated_handles INT;
      updated_display_names INT;
    BEGIN
      SELECT COUNT(*) INTO updated_unique_ids
      FROM users
      WHERE updated_at >= NOW() - INTERVAL '1 minute'
      AND unique_id IS NOT NULL;

      SELECT COUNT(*) INTO updated_handles
      FROM users
      WHERE updated_at >= NOW() - INTERVAL '1 minute'
      AND handle IS NOT NULL;

      SELECT COUNT(*) INTO updated_display_names
      FROM users
      WHERE updated_at >= NOW() - INTERVAL '1 minute'
      AND display_name IS NOT NULL;

      RAISE NOTICE 'Regenerated % unique IDs, % handles, and % display names',
        updated_unique_ids, updated_handles, updated_display_names;
    END $$;
    """)
  end

  def down do
    # We don't remove the generated data on rollback
    # as that would be destructive
    :ok
  end
end
