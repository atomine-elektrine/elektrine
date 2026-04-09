defmodule Elektrine.Repo.Migrations.CreateChatModerationTablesAndSafetyChecks do
  use Ecto.Migration

  def up do
    create table(:chat_user_timeouts) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :timeout_until, :utc_datetime
      add :reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_user_timeouts, [:user_id, :conversation_id],
             name: :chat_user_timeouts_user_conversation_unique
           )

    create table(:chat_moderation_actions) do
      add :action_type, :string
      add :reason, :string
      add :duration, :integer
      add :details, :map
      add :target_user_id, references(:users, on_delete: :nilify_all)
      add :moderator_id, references(:users, on_delete: :nilify_all)
      add :conversation_id, references(:chat_conversations, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:chat_moderation_actions, [:conversation_id])
    create index(:chat_moderation_actions, [:target_user_id])
    create index(:chat_moderation_actions, [:moderator_id])

    execute("""
    INSERT INTO chat_user_timeouts (
      user_id,
      conversation_id,
      created_by_id,
      timeout_until,
      reason,
      inserted_at,
      updated_at
    )
    SELECT
      ut.user_id,
      ut.conversation_id,
      ut.created_by_id,
      ut.timeout_until,
      ut.reason,
      ut.inserted_at,
      ut.updated_at
    FROM user_timeouts ut
    INNER JOIN conversations c ON c.id = ut.conversation_id
    WHERE c.type IN ('dm', 'group', 'channel')
    ON CONFLICT (user_id, conversation_id) DO NOTHING
    """)

    execute("""
    DELETE FROM user_timeouts ut
    USING conversations c
    WHERE c.id = ut.conversation_id
      AND c.type IN ('dm', 'group', 'channel')
    """)

    execute("""
    INSERT INTO chat_moderation_actions (
      action_type,
      reason,
      duration,
      details,
      target_user_id,
      moderator_id,
      conversation_id,
      inserted_at,
      updated_at
    )
    SELECT
      ma.action_type,
      ma.reason,
      ma.duration,
      ma.details,
      ma.target_user_id,
      ma.moderator_id,
      ma.conversation_id,
      ma.inserted_at,
      ma.updated_at
    FROM moderation_actions ma
    INNER JOIN conversations c ON c.id = ma.conversation_id
    WHERE c.type IN ('dm', 'group', 'channel')
    """)

    execute("""
    DELETE FROM moderation_actions ma
    USING conversations c
    WHERE c.id = ma.conversation_id
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

      legacy_count := timeout_count + action_count + note_count + warning_count + timestamp_count + rule_count + ban_count;

      IF legacy_count > 0 THEN
        RAISE EXCEPTION 'Cannot finalize chat split: remaining legacy references total=% user_timeouts=% moderation_actions=% moderator_notes=% user_warnings=% user_post_timestamps=% auto_mod_rules=% community_bans=%',
          legacy_count,
          timeout_count,
          action_count,
          note_count,
          warning_count,
          timestamp_count,
          rule_count,
          ban_count;
      END IF;
    END $$;
    """)
  end

  def down do
    drop table(:chat_moderation_actions)
    drop table(:chat_user_timeouts)
  end
end
