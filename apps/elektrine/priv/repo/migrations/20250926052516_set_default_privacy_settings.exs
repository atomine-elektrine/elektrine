defmodule Elektrine.Repo.Migrations.SetDefaultPrivacySettings do
  use Ecto.Migration

  def up do
    # Set defaults for existing users where fields are NULL
    execute """
    UPDATE users
    SET
      profile_visibility = COALESCE(profile_visibility, 'public'),
      allow_group_adds_from = COALESCE(allow_group_adds_from, 'everyone'),
      allow_direct_messages_from = COALESCE(allow_direct_messages_from, 'everyone'),
      allow_mentions_from = COALESCE(allow_mentions_from, 'everyone'),
      email_on_new_follower = COALESCE(email_on_new_follower, true),
      email_on_direct_message = COALESCE(email_on_direct_message, true),
      email_on_mention = COALESCE(email_on_mention, true),
      email_on_group_invite = COALESCE(email_on_group_invite, true)
    """
  end

  def down do
    # We can't undo this data migration
  end
end
