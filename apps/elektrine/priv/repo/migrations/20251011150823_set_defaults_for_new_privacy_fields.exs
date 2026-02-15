defmodule Elektrine.Repo.Migrations.SetDefaultsForNewPrivacyFields do
  use Ecto.Migration

  def up do
    # Set defaults for existing users where fields are NULL
    # These fields were added in later migrations and might not have defaults for existing users
    execute """
    UPDATE users
    SET
      allow_calls_from = COALESCE(allow_calls_from, 'friends'),
      allow_friend_requests_from = COALESCE(allow_friend_requests_from, 'everyone'),
      default_post_visibility = COALESCE(default_post_visibility, 'followers')
    WHERE allow_calls_from IS NULL
       OR allow_friend_requests_from IS NULL
       OR default_post_visibility IS NULL
    """
  end

  def down do
    # We can't undo this data migration
  end
end
