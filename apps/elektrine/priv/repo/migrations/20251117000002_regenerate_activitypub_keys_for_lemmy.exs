defmodule Elektrine.Repo.Migrations.RegenerateActivitypubKeysForLemmy do
  use Ecto.Migration

  def up do
    # Clear existing ActivityPub keys to force regeneration in PKCS#8 format
    # The KeyManager.generate_key_pair/0 function will regenerate them properly
    # when needed, using openssl to create Lemmy-compatible PUBLIC KEY format

    execute """
    UPDATE users
    SET activitypub_public_key = NULL,
        activitypub_private_key = NULL
    WHERE activitypub_public_key IS NOT NULL
    """
  end

  def down do
    # Can't restore old keys, but they'll be regenerated on next use
    :ok
  end
end
