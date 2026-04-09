defmodule Elektrine.Repo.Migrations.DeleteLegacyChatConversations do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM messages m
    USING conversations c
    WHERE c.id = m.conversation_id
      AND c.type IN ('dm', 'group', 'channel')
    """)

    execute("""
    DO $$
    DECLARE
      timeout_count bigint;
      action_count bigint;
      note_count bigint;
      warning_count bigint;
      timestamp_count bigint;
      rule_count bigint;
      ban_count bigint;
      message_count bigint;
      legacy_count bigint;
    BEGIN
      SELECT count(*) INTO timeout_count
      FROM user_timeouts ut
      JOIN conversations c ON c.id = ut.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO action_count
      FROM moderation_actions ma
      JOIN conversations c ON c.id = ma.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO note_count
      FROM moderator_notes mn
      JOIN conversations c ON c.id = mn.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO warning_count
      FROM user_warnings uw
      JOIN conversations c ON c.id = uw.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO timestamp_count
      FROM user_post_timestamps upt
      JOIN conversations c ON c.id = upt.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO rule_count
      FROM auto_mod_rules amr
      JOIN conversations c ON c.id = amr.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO ban_count
      FROM community_bans cb
      JOIN conversations c ON c.id = cb.conversation_id
      WHERE c.type IN ('dm','group','channel');

      SELECT count(*) INTO message_count
      FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      WHERE c.type IN ('dm','group','channel');

      legacy_count := timeout_count + action_count + note_count + warning_count + timestamp_count + rule_count + ban_count + message_count;

      IF legacy_count > 0 THEN
        RAISE EXCEPTION 'Cannot delete legacy chat conversations: remaining legacy references total=% user_timeouts=% moderation_actions=% moderator_notes=% user_warnings=% user_post_timestamps=% auto_mod_rules=% community_bans=% messages=%',
          legacy_count,
          timeout_count,
          action_count,
          note_count,
          warning_count,
          timestamp_count,
          rule_count,
          ban_count,
          message_count;
      END IF;
    END $$;
    """)

    execute("DELETE FROM conversations WHERE type IN ('dm','group','channel')")
  end

  def down do
    raise "Irreversible migration"
  end
end
