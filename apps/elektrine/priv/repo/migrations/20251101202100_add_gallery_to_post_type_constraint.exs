defmodule Elektrine.Repo.Migrations.AddGalleryToPostTypeConstraint do
  use Ecto.Migration

  def up do
    # Drop the old check constraint
    execute "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_post_type_check"

    # Add the new check constraint with "gallery" included
    execute """
    ALTER TABLE messages ADD CONSTRAINT messages_post_type_check
    CHECK (post_type IN ('message', 'post', 'comment', 'share', 'discussion', 'link', 'poll', 'gallery'))
    """
  end

  def down do
    # Drop the new constraint
    execute "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_post_type_check"

    # Restore the old constraint without "gallery"
    execute """
    ALTER TABLE messages ADD CONSTRAINT messages_post_type_check
    CHECK (post_type IN ('message', 'post', 'comment', 'share', 'discussion', 'link', 'poll'))
    """
  end
end
