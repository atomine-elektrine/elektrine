defmodule Elektrine.Repo.Migrations.DeleteLegacyChatConversations do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      legacy_count bigint;
    BEGIN
      SELECT (
        (SELECT count(*) FROM user_timeouts ut JOIN conversations c ON c.id = ut.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM moderation_actions ma JOIN conversations c ON c.id = ma.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM moderator_notes mn JOIN conversations c ON c.id = mn.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM user_warnings uw JOIN conversations c ON c.id = uw.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM user_post_timestamps upt JOIN conversations c ON c.id = upt.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM auto_mod_rules amr JOIN conversations c ON c.id = amr.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM community_bans cb JOIN conversations c ON c.id = cb.conversation_id WHERE c.type IN ('dm','group','channel')) +
        (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id WHERE c.type IN ('dm','group','channel'))
      ) INTO legacy_count;

      IF legacy_count > 0 THEN
        RAISE EXCEPTION 'Cannot delete legacy chat conversations: % remaining legacy references found', legacy_count;
      END IF;
    END $$;
    """)

    execute("DELETE FROM conversations WHERE type IN ('dm','group','channel')")
  end

  def down do
    raise "Irreversible migration"
  end
end
