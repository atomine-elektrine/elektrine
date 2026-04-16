defmodule Elektrine.Repo.Migrations.AddFederationAndImapHotPathIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_activitypub_url_not_null_idx
    ON messages (activitypub_url)
    WHERE activitypub_url IS NOT NULL
    """)

    create_if_not_exists index(:email_messages, [:mailbox_id, :id],
                           concurrently: true,
                           where:
                             "reply_later_at IS NULL AND NOT spam AND NOT archived AND NOT deleted",
                           name: :email_messages_imap_inbox_mailbox_id_id_idx
                         )
  end

  def down do
    drop_if_exists index(:email_messages, [:mailbox_id, :id],
                     concurrently: true,
                     name: :email_messages_imap_inbox_mailbox_id_id_idx
                   )
  end
end
