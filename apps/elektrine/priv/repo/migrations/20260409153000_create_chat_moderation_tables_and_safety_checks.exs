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
        (SELECT count(*) FROM community_bans cb JOIN conversations c ON c.id = cb.conversation_id WHERE c.type IN ('dm','group','channel'))
      ) INTO legacy_count;

      IF legacy_count > 0 THEN
        RAISE EXCEPTION 'Cannot finalize chat split: legacy moderation/support tables still reference chat conversations (%)', legacy_count;
      END IF;
    END $$;
    """)
  end

  def down do
    drop table(:chat_moderation_actions)
    drop table(:chat_user_timeouts)
  end
end
