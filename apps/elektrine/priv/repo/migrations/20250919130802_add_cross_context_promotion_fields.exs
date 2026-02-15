defmodule Elektrine.Repo.Migrations.AddCrossContextPromotionFields do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Cross-context promotion tracking
      add :original_message_id, references(:messages, on_delete: :nilify_all)
      add :shared_message_id, references(:messages, on_delete: :nilify_all)
      # "chat", "timeline", "dm", etc.
      add :promoted_from, :string
      # "dm_share", "discussion_share", "timeline_reshare", etc.
      add :share_type, :string
    end

    # Update post_type validation to include new types
    execute(
      "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_post_type_check",
      "ALTER TABLE messages ADD CONSTRAINT messages_post_type_check CHECK (post_type IN ('message', 'post', 'comment', 'share', 'discussion'))"
    )

    execute(
      "ALTER TABLE messages ADD CONSTRAINT messages_post_type_check CHECK (post_type IN ('message', 'post', 'comment', 'share', 'discussion'))",
      "ALTER TABLE messages DROP CONSTRAINT messages_post_type_check"
    )

    # Add index for efficient cross-context queries
    create index(:messages, [:original_message_id])
    create index(:messages, [:shared_message_id])
    create index(:messages, [:promoted_from])
  end
end
