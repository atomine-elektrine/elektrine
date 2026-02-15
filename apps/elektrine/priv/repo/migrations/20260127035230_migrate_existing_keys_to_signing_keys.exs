defmodule Elektrine.Repo.Migrations.MigrateExistingKeysToSigningKeys do
  use Ecto.Migration

  def up do
    # Get base URL - in production this would be https://z.org
    # The key_id format is: {base_url}/users/{username}#main-key
    base_url = System.get_env("INSTANCE_URL") || "https://z.org"

    # Migrate local user keys
    execute """
    INSERT INTO signing_keys (key_id, user_id, public_key, private_key, inserted_at, updated_at)
    SELECT 
      CONCAT('#{base_url}', '/users/', u.username, '#main-key') as key_id,
      u.id as user_id,
      u.activitypub_public_key as public_key,
      u.activitypub_private_key as private_key,
      COALESCE(u.inserted_at, NOW()) as inserted_at,
      COALESCE(u.updated_at, NOW()) as updated_at
    FROM users u
    WHERE u.activitypub_public_key IS NOT NULL 
      AND u.activitypub_public_key != ''
      AND u.activitypub_enabled = true
    ON CONFLICT (key_id) DO UPDATE SET
      public_key = EXCLUDED.public_key,
      private_key = EXCLUDED.private_key,
      updated_at = NOW()
    """

    # Migrate remote actor keys
    execute """
    INSERT INTO signing_keys (key_id, remote_actor_id, public_key, inserted_at, updated_at)
    SELECT 
      CONCAT(ra.uri, '#main-key') as key_id,
      ra.id as remote_actor_id,
      ra.public_key as public_key,
      COALESCE(ra.inserted_at, NOW()) as inserted_at,
      COALESCE(ra.updated_at, NOW()) as updated_at
    FROM activitypub_actors ra
    WHERE ra.public_key IS NOT NULL 
      AND ra.public_key != ''
    ON CONFLICT (key_id) DO UPDATE SET
      public_key = EXCLUDED.public_key,
      updated_at = NOW()
    """
  end

  def down do
    # Remove migrated keys
    execute "DELETE FROM signing_keys"
  end
end
