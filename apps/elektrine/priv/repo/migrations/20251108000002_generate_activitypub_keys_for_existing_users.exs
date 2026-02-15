defmodule Elektrine.Repo.Migrations.GenerateActivitypubKeysForExistingUsers do
  use Ecto.Migration

  def up do
    # This migration will be run after the schema migration
    # We'll generate keys for existing users in a separate task
    # Run: mix run priv/repo/generate_activitypub_keys.exs
    :ok
  end

  def down do
    :ok
  end
end
