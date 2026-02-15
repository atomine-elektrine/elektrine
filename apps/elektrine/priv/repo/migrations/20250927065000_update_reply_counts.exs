defmodule Elektrine.Repo.Migrations.UpdateReplyCounts do
  use Ecto.Migration

  def up do
    # Update reply counts for all messages
    execute """
    UPDATE messages m
    SET reply_count = (
      SELECT COUNT(*)
      FROM messages r
      WHERE r.reply_to_id = m.id
        AND r.deleted_at IS NULL
    )
    WHERE m.post_type = 'discussion'
      AND m.reply_to_id IS NULL
    """
  end

  def down do
    # Reset all reply counts to 0
    execute """
    UPDATE messages
    SET reply_count = 0
    WHERE post_type = 'discussion'
    """
  end
end
