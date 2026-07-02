defmodule Elektrine.Repo.Migrations.GuardBoostsAgainstDeletedMessages do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION reject_deleted_message_boost()
    RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM social_messages
        WHERE id = NEW.message_id
          AND deleted_at IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'cannot boost deleted social_message %', NEW.message_id
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("DROP TRIGGER IF EXISTS reject_deleted_message_post_boost ON post_boosts;")

    execute("""
    CREATE TRIGGER reject_deleted_message_post_boost
    BEFORE INSERT OR UPDATE OF message_id ON post_boosts
    FOR EACH ROW EXECUTE FUNCTION reject_deleted_message_boost();
    """)

    execute("DROP TRIGGER IF EXISTS reject_deleted_message_federated_boost ON federated_boosts;")

    execute("""
    CREATE TRIGGER reject_deleted_message_federated_boost
    BEFORE INSERT OR UPDATE OF message_id ON federated_boosts
    FOR EACH ROW EXECUTE FUNCTION reject_deleted_message_boost();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS reject_deleted_message_post_boost ON post_boosts;")
    execute("DROP TRIGGER IF EXISTS reject_deleted_message_federated_boost ON federated_boosts;")
    execute("DROP FUNCTION IF EXISTS reject_deleted_message_boost();")
  end
end
